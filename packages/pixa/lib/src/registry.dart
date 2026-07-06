import 'dart:typed_data';

import 'contracts.dart';
import 'image_format.dart';
import 'observer.dart';

/// Execution layer used by a plugin descriptor.
enum PixaPluginExecutionKind {
  /// Runs inside Pixa's shared runtime through the stable runtime ABI.
  runtime,

  /// Runs in Dart. This is opt-in and not used by default hot paths.
  dart,

  /// Runs outside the Pixa host, such as a process or platform service.
  external,
}

/// Runtime ABI deployment mode for a plugin module.
enum PixaRuntimeDeployment {
  /// The module is compiled into Pixa's host runtime.
  builtInHostModule,

  /// A third-party module linked into Pixa's host binary at app build time.
  hostLinkedPluginModule,

  /// The module is supplied by an asset-module dynamic library.
  assetModule,
}

/// Stable runtime ABI contract used by plugin implementations.
final class PixaRuntimeContract {
  /// Creates a descriptor for a module compiled into Pixa's runtime.
  const PixaRuntimeContract.builtInHostModule({
    required this.moduleId,
    this.abiVersion = 1,
    this.packageName,
    this.implementationLanguage,
    this.hostManagedRuntime = true,
    this.binaryMessages = true,
    this.ownedBuffers = true,
    this.streamHandles = true,
  }) : deployment = PixaRuntimeDeployment.builtInHostModule,
       assetId = null,
       entrypointSymbol = null;

  /// Creates a descriptor for a plugin linked into Pixa's host binary.
  const PixaRuntimeContract.hostLinkedPluginModule({
    required this.moduleId,
    required this.entrypointSymbol,
    this.packageName,
    this.implementationLanguage,
    this.abiVersion = 1,
    this.hostManagedRuntime = true,
    this.binaryMessages = true,
    this.ownedBuffers = true,
    this.streamHandles = true,
  }) : deployment = PixaRuntimeDeployment.hostLinkedPluginModule,
       assetId = null;

  /// Creates a descriptor for an asset module using Pixa's host ABI.
  const PixaRuntimeContract.assetModule({
    required this.moduleId,
    required this.assetId,
    required this.entrypointSymbol,
    this.packageName,
    this.implementationLanguage,
    this.abiVersion = 1,
    this.hostManagedRuntime = true,
    this.binaryMessages = true,
    this.ownedBuffers = true,
    this.streamHandles = true,
  }) : deployment = PixaRuntimeDeployment.assetModule;

  /// ABI version understood by the Pixa runtime host.
  final int abiVersion;

  /// Deployment shape for this runtime module.
  final PixaRuntimeDeployment deployment;

  /// Stable module id inside the Pixa runtime host.
  final String moduleId;

  /// Dart package or runtime module package that contributed the module.
  final String? packageName;

  /// Implementation language label for diagnostics, not for dispatch.
  ///
  /// Any language is acceptable if it exposes the Pixa runtime ABI and obeys the
  /// ownership, cancellation and binary-message contract.
  final String? implementationLanguage;

  /// Library asset id when [deployment] is [assetModule].
  final String? assetId;

  /// ABI entrypoint symbol when [deployment] is [assetModule].
  final String? entrypointSymbol;

  /// Whether scheduling, cancellation, progress and cache ownership stay in Pixa.
  final bool hostManagedRuntime;

  /// Whether control payloads use compact binary messages rather than JSON.
  final bool binaryMessages;

  /// Whether large returned buffers use explicit ownership and explicit release.
  final bool ownedBuffers;

  /// Whether large input/output streams can be passed by handle.
  final bool streamHandles;

  /// Whether this module can be folded into Pixa's single runtime host binary.
  bool get canLinkIntoHostBinary {
    return deployment == PixaRuntimeDeployment.builtInHostModule ||
        deployment == PixaRuntimeDeployment.hostLinkedPluginModule;
  }
}

/// Aggregated registry shape used by validation, debug tools and build hooks.
final class PixaRegistryArchitectureSnapshot {
  /// Creates a registry architecture snapshot.
  const PixaRegistryArchitectureSnapshot({
    required this.fetchers,
    required this.decoders,
    required this.processors,
    required this.cacheStores,
    required this.videoFrameBackends,
    required this.videoFrameBackendsUseRuntimeOnly,
    required this.videoFrameEncodedOutputBackends,
    required this.decoderSignatureRoutes,
    required this.decodersWithMetadataProbe,
    required this.decodersWithRegionDecode,
    required this.decodersWithStreamingInput,
    required this.runtimeHandlers,
    required this.dartHandlers,
    required this.externalHandlers,
    required this.runtimeModules,
    required this.builtInHostModules,
    required this.hostLinkedPluginModules,
    required this.assetModules,
    required this.linkableRuntimeModules,
    required this.allRuntimeHandlersUseHostRuntime,
    required this.allRuntimeHandlersUseBinaryMessages,
    required this.allRuntimeHandlersUseOwnedBuffers,
    required this.allRuntimeHandlersUseStreamHandles,
  });

  /// Fetcher descriptor count.
  final int fetchers;

  /// Decoder descriptor count.
  final int decoders;

  /// Processor descriptor count.
  final int processors;

  /// Cache-store descriptor count.
  final int cacheStores;

  /// Video-frame backend descriptor count.
  final int videoFrameBackends;

  /// Whether all video-frame backends run through the runtime ABI.
  final bool videoFrameBackendsUseRuntimeOnly;

  /// Video-frame backends that return supported encoded image payloads.
  final int videoFrameEncodedOutputBackends;

  /// Bounded-header decoder signature route count.
  final int decoderSignatureRoutes;

  /// Decoders that can parse bounded encoded metadata before full decode.
  final int decodersWithMetadataProbe;

  /// Decoders that can decode visible regions without full-frame decode.
  final int decodersWithRegionDecode;

  /// Decoders that can consume large inputs through stream handles.
  final int decodersWithStreamingInput;

  /// Descriptor count that executes through the runtime ABI.
  final int runtimeHandlers;

  /// Descriptor count that executes in Dart.
  final int dartHandlers;

  /// Descriptor count that declares an external boundary.
  final int externalHandlers;

  /// Unique runtime module count.
  final int runtimeModules;

  /// Unique modules compiled into the Pixa runtime host.
  final int builtInHostModules;

  /// Unique modules linked into the final host binary at app build time.
  final int hostLinkedPluginModules;

  /// Unique modules loaded through an asset-module boundary.
  final int assetModules;

  /// Unique runtime modules that can share one final host binary.
  final int linkableRuntimeModules;

  /// Runtime ABI handlers keep scheduling/cancel/progress inside Pixa.
  final bool allRuntimeHandlersUseHostRuntime;

  /// Runtime ABI handlers use compact binary messages, not JSON.
  final bool allRuntimeHandlersUseBinaryMessages;

  /// Runtime handlers return large buffers with explicit ownership.
  final bool allRuntimeHandlersUseOwnedBuffers;

  /// Runtime ABI handlers can pass large streams by handle.
  final bool allRuntimeHandlersUseStreamHandles;

  /// True when runtime handlers can be folded into one host binary.
  bool get runtimeCanUseSingleHostBinary {
    return runtimeHandlers == 0 ||
        (assetModules == 0 &&
            linkableRuntimeModules == runtimeModules &&
            allRuntimeHandlersUseHostRuntime &&
            allRuntimeHandlersUseBinaryMessages &&
            allRuntimeHandlersUseOwnedBuffers &&
            allRuntimeHandlersUseStreamHandles);
  }

  /// True when no descriptor can enter a non-runtime execution path.
  bool get defaultHotPathUsesRuntimeOnly {
    return dartHandlers == 0 && externalHandlers == 0;
  }

  /// JSON-like representation for debug surfaces.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'fetchers': fetchers,
      'decoders': decoders,
      'processors': processors,
      'cacheStores': cacheStores,
      'videoFrameBackends': videoFrameBackends,
      'videoFrameBackendsUseRuntimeOnly': videoFrameBackendsUseRuntimeOnly,
      'videoFrameEncodedOutputBackends': videoFrameEncodedOutputBackends,
      'decoderSignatureRoutes': decoderSignatureRoutes,
      'decodersWithMetadataProbe': decodersWithMetadataProbe,
      'decodersWithRegionDecode': decodersWithRegionDecode,
      'decodersWithStreamingInput': decodersWithStreamingInput,
      'runtimeHandlers': runtimeHandlers,
      'dartHandlers': dartHandlers,
      'externalHandlers': externalHandlers,
      'runtimeModules': runtimeModules,
      'builtInHostModules': builtInHostModules,
      'hostLinkedPluginModules': hostLinkedPluginModules,
      'assetModules': assetModules,
      'linkableRuntimeModules': linkableRuntimeModules,
      'allRuntimeHandlersUseHostRuntime': allRuntimeHandlersUseHostRuntime,
      'allRuntimeHandlersUseBinaryMessages':
          allRuntimeHandlersUseBinaryMessages,
      'allRuntimeHandlersUseOwnedBuffers': allRuntimeHandlersUseOwnedBuffers,
      'allRuntimeHandlersUseStreamHandles': allRuntimeHandlersUseStreamHandles,
      'runtimeCanUseSingleHostBinary': runtimeCanUseSingleHostBinary,
      'defaultHotPathUsesRuntimeOnly': defaultHotPathUsesRuntimeOnly,
    };
  }
}

/// Production capability contract for one decoder adapter.
final class PixaDecoderCapabilities {
  /// Creates an explicit decoder capability contract.
  const PixaDecoderCapabilities({
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

  /// Runtime raster decoder defaults for production image hot paths.
  const PixaDecoderCapabilities.runtimeRaster({
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

  /// Explicit Dart decoder defaults for opt-in non-default plugin paths.
  const PixaDecoderCapabilities.dartBytes({
    this.metadataProbe = false,
    this.staticDecode = true,
    this.animatedDecode = false,
    this.progressiveDecode = false,
    this.regionDecode = false,
    this.processorInput = false,
    this.streamingInput = false,
    this.defaultRuntimeDisplay = false,
    this.stable = true,
  }) : zeroCopyInput = false,
       ownedOutputBuffers = false;

  /// Can read dimensions/flags from bounded headers.
  final bool metadataProbe;

  /// Can decode at least one static image frame.
  final bool staticDecode;

  /// Can decode animated image streams.
  final bool animatedDecode;

  /// Can produce progressive/intermediate decode output while streaming.
  final bool progressiveDecode;

  /// Can decode a requested region/tile without full-frame pixel decode.
  final bool regionDecode;

  /// Can provide decoded pixels to runtime processors.
  final bool processorInput;

  /// Can consume large inputs through Pixa stream handles.
  final bool streamingInput;

  /// Should be selected as the default runtime display backend.
  final bool defaultRuntimeDisplay;

  /// Can consume encoded input by borrowed bytes or handles without copying.
  final bool zeroCopyInput;

  /// Returns large outputs through owned runtime buffers.
  final bool ownedOutputBuffers;

  /// Has fixtures, limits and compatibility coverage for production use.
  final bool stable;

  /// True when the decoder can run on gallery hot paths.
  bool get hotPathSafe {
    return stable && zeroCopyInput && ownedOutputBuffers;
  }
}

/// Bounded static signature route for a decoder adapter.
final class PixaDecoderSignature {
  /// Creates a bounded-header decoder signature.
  const PixaDecoderSignature({
    required this.offset,
    required this.magic,
    required this.mimeType,
    this.formatId,
  });

  /// Byte offset within the first encoded header bytes.
  final int offset;

  /// Magic bytes to compare at [offset].
  final List<int> magic;

  /// MIME type emitted when this signature matches.
  final String mimeType;

  /// Stable encoded format id emitted when this signature matches.
  final String? formatId;

  /// Stable conflict key for registry validation.
  String get routeKey => '$offset:${_hexBytes(magic)}';

  /// Whether this signature matches [bytes].
  bool matches(Uint8List bytes) {
    if (offset < 0 || magic.isEmpty || bytes.length < offset + magic.length) {
      return false;
    }
    for (int index = 0; index < magic.length; index += 1) {
      if (bytes[offset + index] != magic[index]) {
        return false;
      }
    }
    return true;
  }

  void _validate() {
    if (offset < 0) {
      throw StateError('Pixa decoder signature offset must be non-negative.');
    }
    if (magic.isEmpty || magic.length > 64) {
      throw StateError('Pixa decoder signature magic must be 1-64 bytes.');
    }
    if (offset + magic.length > 4096) {
      throw StateError(
        'Pixa decoder signature must fit in the first 4096 header bytes.',
      );
    }
    for (final int byte in magic) {
      if (byte < 0 || byte > 0xff) {
        throw StateError('Pixa decoder signature magic contains a non-byte.');
      }
    }
    if (_normalizeMimeType(mimeType).isEmpty) {
      throw StateError('Pixa decoder signature MIME type must not be empty.');
    }
    final String? id = formatId;
    if (id != null && _normalizeRouteClaim(id).isEmpty) {
      throw StateError('Pixa decoder signature format id must not be empty.');
    }
  }
}

/// Shared plugin handler contract.
abstract interface class PixaRegistryHandler {
  /// Stable handler id.
  String get id;
}

/// Descriptor that executes through the runtime ABI.
abstract interface class PixaRuntimeDescriptor implements PixaRegistryHandler {
  /// Runtime ABI contract for this descriptor.
  PixaRuntimeContract get runtime;
}

/// Fetcher extension descriptor.
abstract interface class PixaFetcherDescriptor implements PixaRegistryHandler {
  /// Execution layer used by this fetcher.
  PixaPluginExecutionKind get executionKind;

  /// Source kinds handled by this fetcher, such as `s3` or `content`.
  Set<String> get sourceKinds;
}

/// Payload shape produced by a video-frame backend.
enum PixaVideoFrameOutputKind {
  /// Backend returns a regular encoded image, such as PNG or JPEG.
  encodedImage,
}

/// Production capability contract for a video-frame backend.
final class PixaVideoFrameBackendCapabilities {
  /// Creates capabilities for a backend that returns encoded image bytes.
  const PixaVideoFrameBackendCapabilities.encodedImage({
    required this.outputMimeTypes,
    this.nearestFrame = true,
    this.exactFrame = false,
    this.fileLocator = true,
    this.networkLocator = false,
    this.contentLocator = false,
    this.stable = true,
  }) : outputKind = PixaVideoFrameOutputKind.encodedImage;

  /// Output payload kind.
  final PixaVideoFrameOutputKind outputKind;

  /// Supported encoded image MIME types returned by this backend.
  final Set<String> outputMimeTypes;

  /// Backend can select the nearest efficiently decodable frame.
  final bool nearestFrame;

  /// Backend can require the exact requested timestamp.
  final bool exactFrame;

  /// Backend accepts local filesystem locators.
  final bool fileLocator;

  /// Backend accepts HTTP/HTTPS locators through Pixa runtime scheduling.
  final bool networkLocator;

  /// Backend accepts platform content/library locators.
  final bool contentLocator;

  /// Backend has fixtures, limits and platform compatibility coverage.
  final bool stable;

  /// Whether output is a supported encoded image payload.
  bool get encodedImageOutput {
    return outputKind == PixaVideoFrameOutputKind.encodedImage;
  }

  /// True when the backend can run on production gallery hot paths.
  bool get hotPathSafe {
    return stable &&
        (nearestFrame || exactFrame) &&
        (fileLocator || networkLocator || contentLocator) &&
        encodedImageOutput &&
        outputMimeTypes.isNotEmpty;
  }
}

/// Explicit video-frame fetcher descriptor.
abstract interface class PixaVideoFrameBackendDescriptor
    implements PixaFetcherDescriptor {
  /// Optional backend route. `null` claims the default `video-frame` route.
  String? get backendId;

  /// Video-frame extraction capabilities.
  PixaVideoFrameBackendCapabilities get capabilities;
}

/// Runtime ABI video-frame backend descriptor.
final class PixaRuntimeVideoFrameBackendDescriptor
    implements PixaVideoFrameBackendDescriptor, PixaRuntimeDescriptor {
  /// Creates a runtime video-frame backend descriptor.
  const PixaRuntimeVideoFrameBackendDescriptor({
    required this.id,
    required this.runtime,
    this.backendId,
    this.capabilities = const PixaVideoFrameBackendCapabilities.encodedImage(
      outputMimeTypes: <String>{'image/png'},
    ),
  });

  @override
  final String id;

  @override
  final String? backendId;

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.runtime;

  @override
  Set<String> get sourceKinds {
    final String? normalized = _normalizeOptionalRouteClaim(backendId);
    return <String>{
      normalized == null ? 'video-frame' : 'video-frame:$normalized',
    };
  }

  @override
  final PixaVideoFrameBackendCapabilities capabilities;

  @override
  final PixaRuntimeContract runtime;
}

/// Fetcher descriptor with an explicit Dart plugin handler.
abstract interface class PixaDartFetcherDescriptor
    implements PixaFetcherDescriptor {
  /// Fetcher implementation.
  PixaFetcher get fetcher;
}

/// Decoder extension descriptor.
abstract interface class PixaDecoderDescriptor implements PixaRegistryHandler {
  /// Execution layer used by this decoder.
  PixaPluginExecutionKind get executionKind;

  /// MIME types handled by this decoder.
  Set<String> get mimeTypes;

  /// Stable encoded format ids handled by this decoder.
  ///
  /// Format ids are lower-level route keys such as `png`, `qoi`, or a
  /// plugin-defined id. They let decoder plugins declare capability before a
  /// MIME type is known or reliable.
  Set<String> get formatIds;

  /// Bounded-header byte signatures handled by this decoder.
  List<PixaDecoderSignature> get signatures;

  /// Decoder capability contract used by routing, docs and validation.
  PixaDecoderCapabilities get capabilities;

  /// Higher priority wins for the same MIME type.
  int get priority;
}

/// Decoder descriptor with an explicit Dart plugin handler.
abstract interface class PixaDartDecoderDescriptor
    implements PixaDecoderDescriptor {
  /// Decoder implementation.
  PixaDecoder get decoder;
}

/// Processor extension descriptor.
abstract interface class PixaProcessorDescriptor
    implements PixaRegistryHandler {
  /// Execution layer used by this processor.
  PixaPluginExecutionKind get executionKind;

  /// Stable processor operation names.
  Set<String> get operations;
}

/// Processor descriptor with an explicit Dart plugin handler.
abstract interface class PixaDartProcessorDescriptor
    implements PixaProcessorDescriptor {
  /// Processor implementation.
  PixaProcessor get processor;
}

/// Encoded cache store extension descriptor.
abstract interface class PixaCacheStoreDescriptor
    implements PixaRegistryHandler {
  /// Execution layer used by this cache store.
  PixaPluginExecutionKind get executionKind;

  /// Cache store namespace handled by this descriptor.
  String get namespace;
}

/// Cache-store descriptor with an explicit Dart plugin handler.
abstract interface class PixaDartCacheStoreDescriptor
    implements PixaCacheStoreDescriptor {
  /// Cache-store implementation.
  PixaCacheStore get cacheStore;
}

/// Default cache-store descriptor id for the core Rust-backed store.
const String pixaCacheStoreDescriptorId = 'pixa.cache_store';

/// Default namespace for the core Rust-backed store descriptor.
const String pixaCacheStoreNamespace = 'default';

/// Cache-store implementation engine.
enum PixaCacheStoreEngine {
  /// Pixa's Rust image-cache store.
  rustRuntime,
}

/// Capabilities required from a production Pixa cache store.
final class PixaCacheStoreCapabilities {
  /// Creates a capability description.
  const PixaCacheStoreCapabilities({
    required this.binaryValues,
    required this.metadataSidecar,
    required this.atomicWrites,
    required this.checksumValidation,
    required this.ttl,
    required this.namespaceIsolation,
    required this.sizeEviction,
    required this.corruptionRecovery,
    required this.concurrentEntryGuards,
    required this.ownedReadBuffers,
    required this.dartStorageRuntime,
  });

  /// Pixa's runtime image-cache store capabilities.
  const PixaCacheStoreCapabilities.runtimeImageCache()
    : this(
        binaryValues: true,
        metadataSidecar: true,
        atomicWrites: true,
        checksumValidation: true,
        ttl: true,
        namespaceIsolation: true,
        sizeEviction: true,
        corruptionRecovery: true,
        concurrentEntryGuards: true,
        ownedReadBuffers: true,
        dartStorageRuntime: false,
      );

  /// Stores encoded image bytes as binary values.
  final bool binaryValues;

  /// Persists structured metadata next to bytes.
  final bool metadataSidecar;

  /// Writes are crash-safe and not visible until complete.
  final bool atomicWrites;

  /// Reads validate length/checksum before returning bytes.
  final bool checksumValidation;

  /// Entries can expire by time-to-live.
  final bool ttl;

  /// Namespaces are isolated for clear/evict/privacy policy.
  final bool namespaceIsolation;

  /// Store can evict old entries by byte budget.
  final bool sizeEviction;

  /// Corrupt entries are removed instead of returned.
  final bool corruptionRecovery;

  /// Same-entry writes are serialized.
  final bool concurrentEntryGuards;

  /// Read buffers are owned by runtime code until explicitly released.
  final bool ownedReadBuffers;

  /// Whether this store requires a Dart-side storage runtime.
  final bool dartStorageRuntime;
}

/// Descriptor for Pixa's built-in Rust-backed image cache store.
final class PixaRuntimeCacheStoreDescriptor
    implements PixaCacheStoreDescriptor, PixaRuntimeDescriptor {
  /// Creates a runtime cache-store descriptor.
  const PixaRuntimeCacheStoreDescriptor({
    this.id = pixaCacheStoreDescriptorId,
    this.namespace = pixaCacheStoreNamespace,
    this.engine = PixaCacheStoreEngine.rustRuntime,
    this.capabilities = const PixaCacheStoreCapabilities.runtimeImageCache(),
    this.runtime = const PixaRuntimeContract.builtInHostModule(
      moduleId: 'pixa.cache_store',
    ),
  });

  @override
  final String id;

  @override
  final String namespace;

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.runtime;

  /// Store engine backing this descriptor.
  final PixaCacheStoreEngine engine;

  /// Production capabilities guaranteed by this store contract.
  final PixaCacheStoreCapabilities capabilities;

  @override
  final PixaRuntimeContract runtime;
}

/// Cache-key extension descriptor.
abstract interface class PixaCacheKeyContributorDescriptor
    implements PixaRegistryHandler {}

/// Debug panel extension descriptor.
abstract interface class PixaDebugPanelDescriptor
    implements PixaRegistryHandler {
  /// Debug panel title.
  String get title;
}

/// Mutable plugin registration surface used during `Pixa.configure`.
final class PixaRegistry {
  /// Creates a registry.
  PixaRegistry();

  final List<PixaObserver> _observers = <PixaObserver>[];
  final Map<String, PixaFetcherDescriptor> _fetchers =
      <String, PixaFetcherDescriptor>{};
  final Map<String, PixaDecoderDescriptor> _decoders =
      <String, PixaDecoderDescriptor>{};
  final Map<String, PixaProcessorDescriptor> _processors =
      <String, PixaProcessorDescriptor>{};
  final Map<String, PixaCacheStoreDescriptor> _cacheStores =
      <String, PixaCacheStoreDescriptor>{};
  final Map<String, PixaCacheKeyContributorDescriptor> _cacheKeyContributors =
      <String, PixaCacheKeyContributorDescriptor>{};
  final Map<String, PixaDebugPanelDescriptor> _debugPanels =
      <String, PixaDebugPanelDescriptor>{};
  final Map<String, String> _fetcherSourceKinds = <String, String>{};
  final Map<String, String> _decoderPriorities = <String, String>{};
  final Map<String, String> _decoderFormatPriorities = <String, String>{};
  final Map<String, String> _decoderSignaturePriorities = <String, String>{};
  final Map<String, String> _processorOperations = <String, String>{};
  final Map<String, String> _cacheStoreNamespaces = <String, String>{};

  /// Registered observers.
  List<PixaObserver> get observers =>
      List<PixaObserver>.unmodifiable(_observers);

  /// Registered fetchers.
  List<PixaFetcherDescriptor> get fetchers =>
      List<PixaFetcherDescriptor>.unmodifiable(_fetchers.values);

  /// Registered video-frame backends.
  List<PixaVideoFrameBackendDescriptor> get videoFrameBackends {
    return List<PixaVideoFrameBackendDescriptor>.unmodifiable(
      _fetchers.values.whereType<PixaVideoFrameBackendDescriptor>(),
    );
  }

  /// Returns the fetcher descriptor registered for [sourceKind], if any.
  PixaFetcherDescriptor? fetcherForSourceKind(String sourceKind) {
    final String? ownerId =
        _fetcherSourceKinds[sourceKind.trim().toLowerCase()];
    return ownerId == null ? null : _fetchers[ownerId];
  }

  /// Registered decoders.
  List<PixaDecoderDescriptor> get decoders =>
      List<PixaDecoderDescriptor>.unmodifiable(_decoders.values);

  /// Returns the highest-priority decoder descriptor for [mimeType], if any.
  PixaDecoderDescriptor? decoderForMimeType(String mimeType) {
    final String normalized = _normalizeMimeType(mimeType);
    if (normalized.isEmpty) {
      return null;
    }
    PixaDecoderDescriptor? selected;
    for (final PixaDecoderDescriptor decoder in _decoders.values) {
      final bool handlesMime = decoder.mimeTypes
          .map(_normalizeMimeType)
          .any((String candidate) => candidate == normalized);
      if (!handlesMime) {
        continue;
      }
      if (selected == null || decoder.priority > selected.priority) {
        selected = decoder;
      }
    }
    return selected;
  }

  /// Returns the highest-priority decoder descriptor for [formatId], if any.
  PixaDecoderDescriptor? decoderForFormatId(String formatId) {
    final String normalized = _normalizeRouteClaim(formatId);
    if (normalized.isEmpty) {
      return null;
    }
    PixaDecoderDescriptor? selected;
    for (final PixaDecoderDescriptor decoder in _decoders.values) {
      final bool handlesFormat = decoder.formatIds
          .map(_normalizeRouteClaim)
          .any((String candidate) => candidate == normalized);
      if (!handlesFormat) {
        continue;
      }
      if (selected == null || decoder.priority > selected.priority) {
        selected = decoder;
      }
    }
    return selected;
  }

  /// Returns the highest-priority decoder descriptor matching [bytes].
  PixaDecoderDescriptor? decoderForSignature(Uint8List bytes) {
    PixaDecoderDescriptor? selected;
    for (final PixaDecoderDescriptor decoder in _decoders.values) {
      if (!decoder.signatures.any(
        (PixaDecoderSignature signature) => signature.matches(bytes),
      )) {
        continue;
      }
      if (selected == null || decoder.priority > selected.priority) {
        selected = decoder;
      }
    }
    return selected;
  }

  /// Returns the best decoder route for explicit hints or encoded payload.
  PixaDecoderDescriptor? decoderForPayload(
    Uint8List bytes, {
    String? formatId,
    String? mimeType,
  }) {
    final String? normalizedFormatId = formatId == null
        ? null
        : _normalizeRouteClaim(formatId).ifNotEmpty;
    if (normalizedFormatId != null) {
      final PixaDecoderDescriptor? decoder = decoderForFormatId(
        normalizedFormatId,
      );
      if (decoder != null) {
        return decoder;
      }
    }
    final String? normalizedMimeType = mimeType == null
        ? null
        : _normalizeMimeType(mimeType).ifNotEmpty;
    if (normalizedMimeType != null) {
      final PixaDecoderDescriptor? decoder = decoderForMimeType(
        normalizedMimeType,
      );
      if (decoder != null) {
        return decoder;
      }
    }
    return decoderForSignature(bytes);
  }

  /// Registered processors.
  List<PixaProcessorDescriptor> get processors =>
      List<PixaProcessorDescriptor>.unmodifiable(_processors.values);

  /// Returns the processor descriptor registered for [operation], if any.
  PixaProcessorDescriptor? processorForOperation(String operation) {
    final String? ownerId =
        _processorOperations[operation.trim().toLowerCase()];
    return ownerId == null ? null : _processors[ownerId];
  }

  /// Registered cache stores.
  List<PixaCacheStoreDescriptor> get cacheStores =>
      List<PixaCacheStoreDescriptor>.unmodifiable(_cacheStores.values);

  /// Registered cache-key contributors.
  List<PixaCacheKeyContributorDescriptor> get cacheKeyContributors =>
      List<PixaCacheKeyContributorDescriptor>.unmodifiable(
        _cacheKeyContributors.values,
      );

  /// Registered debug panels.
  List<PixaDebugPanelDescriptor> get debugPanels =>
      List<PixaDebugPanelDescriptor>.unmodifiable(_debugPanels.values);

  /// Returns an aggregated architecture snapshot for this registry.
  PixaRegistryArchitectureSnapshot architectureSnapshot() {
    final List<PixaRegistryHandler> handlers = <PixaRegistryHandler>[
      ..._fetchers.values,
      ..._decoders.values,
      ..._processors.values,
      ..._cacheStores.values,
    ];
    final Map<String, PixaRuntimeContract> runtimeModules =
        <String, PixaRuntimeContract>{};
    var runtimeHandlers = 0;
    var dartHandlers = 0;
    var externalHandlers = 0;
    var allHostRuntime = true;
    var allBinaryMessages = true;
    var allOwnedBuffers = true;
    var allStreamHandles = true;

    for (final PixaRegistryHandler handler in handlers) {
      final PixaPluginExecutionKind kind = _executionKindFor(handler);
      switch (kind) {
        case PixaPluginExecutionKind.runtime:
          runtimeHandlers++;
          final PixaRuntimeContract contract =
              (handler as PixaRuntimeDescriptor).runtime;
          runtimeModules.putIfAbsent(contract.moduleId, () => contract);
          allHostRuntime = allHostRuntime && contract.hostManagedRuntime;
          allBinaryMessages = allBinaryMessages && contract.binaryMessages;
          allOwnedBuffers = allOwnedBuffers && contract.ownedBuffers;
          allStreamHandles = allStreamHandles && contract.streamHandles;
        case PixaPluginExecutionKind.dart:
          dartHandlers++;
        case PixaPluginExecutionKind.external:
          externalHandlers++;
      }
    }

    var builtInHostModules = 0;
    var hostLinkedPluginModules = 0;
    var assetModules = 0;
    var linkableRuntimeModules = 0;
    for (final PixaRuntimeContract contract in runtimeModules.values) {
      switch (contract.deployment) {
        case PixaRuntimeDeployment.builtInHostModule:
          builtInHostModules++;
        case PixaRuntimeDeployment.hostLinkedPluginModule:
          hostLinkedPluginModules++;
        case PixaRuntimeDeployment.assetModule:
          assetModules++;
      }
      if (contract.canLinkIntoHostBinary) {
        linkableRuntimeModules++;
      }
    }

    return PixaRegistryArchitectureSnapshot(
      fetchers: _fetchers.length,
      decoders: _decoders.length,
      processors: _processors.length,
      cacheStores: _cacheStores.length,
      videoFrameBackends: videoFrameBackends.length,
      videoFrameBackendsUseRuntimeOnly: videoFrameBackends.every(
        (PixaVideoFrameBackendDescriptor backend) =>
            backend.executionKind == PixaPluginExecutionKind.runtime,
      ),
      videoFrameEncodedOutputBackends: videoFrameBackends
          .where(
            (PixaVideoFrameBackendDescriptor backend) =>
                backend.capabilities.encodedImageOutput,
          )
          .length,
      decoderSignatureRoutes: _decoders.values.fold<int>(
        0,
        (int count, PixaDecoderDescriptor decoder) =>
            count + decoder.signatures.length,
      ),
      decodersWithMetadataProbe: _decoders.values
          .where(
            (PixaDecoderDescriptor decoder) =>
                decoder.capabilities.metadataProbe,
          )
          .length,
      decodersWithRegionDecode: _decoders.values
          .where(
            (PixaDecoderDescriptor decoder) =>
                decoder.capabilities.regionDecode,
          )
          .length,
      decodersWithStreamingInput: _decoders.values
          .where(
            (PixaDecoderDescriptor decoder) =>
                decoder.capabilities.streamingInput,
          )
          .length,
      runtimeHandlers: runtimeHandlers,
      dartHandlers: dartHandlers,
      externalHandlers: externalHandlers,
      runtimeModules: runtimeModules.length,
      builtInHostModules: builtInHostModules,
      hostLinkedPluginModules: hostLinkedPluginModules,
      assetModules: assetModules,
      linkableRuntimeModules: linkableRuntimeModules,
      allRuntimeHandlersUseHostRuntime: allHostRuntime,
      allRuntimeHandlersUseBinaryMessages: allBinaryMessages,
      allRuntimeHandlersUseOwnedBuffers: allOwnedBuffers,
      allRuntimeHandlersUseStreamHandles: allStreamHandles,
    );
  }

  /// Registers an observer.
  void registerObserver(PixaObserver observer) {
    _observers.add(observer);
  }

  /// Registers a fetcher descriptor.
  void registerFetcher(PixaFetcherDescriptor fetcher) {
    _validateExecutionContract(fetcher, fetcher.executionKind, 'fetcher');
    _validateVideoFrameFetcher(fetcher);
    _putUnique(_fetchers, fetcher, 'fetcher');
    for (final String sourceKind in fetcher.sourceKinds) {
      _claim(_fetcherSourceKinds, sourceKind, fetcher.id, 'source kind');
    }
  }

  /// Registers a decoder descriptor.
  void registerDecoder(PixaDecoderDescriptor decoder) {
    _validateExecutionContract(decoder, decoder.executionKind, 'decoder');
    _putUnique(_decoders, decoder, 'decoder');
    _validateDecoderCapabilities(decoder);
    if (decoder.mimeTypes.isEmpty &&
        decoder.formatIds.isEmpty &&
        decoder.signatures.isEmpty) {
      throw StateError(
        'Pixa decoder "${decoder.id}" must declare at least one route.',
      );
    }
    for (final String mimeType in decoder.mimeTypes) {
      final String normalizedMimeType = _normalizeMimeType(mimeType);
      if (normalizedMimeType.isEmpty) {
        throw StateError('Pixa decoder MIME type claim must not be empty.');
      }
      _claim(
        _decoderPriorities,
        '$normalizedMimeType#${decoder.priority}',
        decoder.id,
        'decoder priority',
      );
    }
    for (final String formatId in decoder.formatIds) {
      final String normalizedFormatId = _normalizeRouteClaim(formatId);
      if (normalizedFormatId.isEmpty) {
        throw StateError('Pixa decoder format id claim must not be empty.');
      }
      _claim(
        _decoderFormatPriorities,
        '$normalizedFormatId#${decoder.priority}',
        decoder.id,
        'decoder format priority',
      );
    }
    for (final PixaDecoderSignature signature in decoder.signatures) {
      signature._validate();
      _claim(
        _decoderSignaturePriorities,
        '${signature.routeKey}#${decoder.priority}',
        decoder.id,
        'decoder signature priority',
      );
    }
  }

  /// Registers a processor descriptor.
  void registerProcessor(PixaProcessorDescriptor processor) {
    _validateExecutionContract(processor, processor.executionKind, 'processor');
    _putUnique(_processors, processor, 'processor');
    for (final String operation in processor.operations) {
      _claim(_processorOperations, operation, processor.id, 'processor');
    }
  }

  /// Registers a cache store descriptor.
  void registerCacheStore(PixaCacheStoreDescriptor cacheStore) {
    _validateExecutionContract(
      cacheStore,
      cacheStore.executionKind,
      'cache store',
    );
    _putUnique(_cacheStores, cacheStore, 'cache store');
    _claim(
      _cacheStoreNamespaces,
      cacheStore.namespace,
      cacheStore.id,
      'cache store namespace',
    );
  }

  /// Registers a cache-key contributor descriptor.
  void registerCacheKeyContributor(
    PixaCacheKeyContributorDescriptor contributor,
  ) {
    _putUnique(_cacheKeyContributors, contributor, 'cache-key contributor');
  }

  /// Registers a debug panel descriptor.
  void registerDebugPanel(PixaDebugPanelDescriptor panel) {
    _putUnique(_debugPanels, panel, 'debug panel');
  }
}

void _validateDecoderCapabilities(PixaDecoderDescriptor decoder) {
  final PixaDecoderCapabilities capabilities = decoder.capabilities;
  if (!capabilities.staticDecode &&
      !capabilities.animatedDecode &&
      !capabilities.metadataProbe) {
    throw StateError(
      'Pixa decoder "${decoder.id}" exposes no decode or metadata capability.',
    );
  }
  if (capabilities.regionDecode && !capabilities.metadataProbe) {
    throw StateError(
      'Pixa decoder "${decoder.id}" region decode requires metadata probe.',
    );
  }
  if (decoder.executionKind == PixaPluginExecutionKind.runtime &&
      !capabilities.hotPathSafe) {
    throw StateError(
      'Pixa runtime decoder "${decoder.id}" must be stable and use zero-copy '
      'input with owned output buffers.',
    );
  }
}

void _validateVideoFrameFetcher(PixaFetcherDescriptor fetcher) {
  final Set<String> normalizedKinds = fetcher.sourceKinds
      .map(_normalizeRouteClaim)
      .where((String value) => value.isNotEmpty)
      .toSet();
  final bool claimsVideoFrame = normalizedKinds.any(_isVideoFrameSourceKind);
  if (!claimsVideoFrame) {
    return;
  }
  if (fetcher is! PixaVideoFrameBackendDescriptor) {
    throw StateError(
      'Pixa video-frame backend routes require a video-frame backend '
      'descriptor.',
    );
  }
  if (fetcher.executionKind != PixaPluginExecutionKind.runtime ||
      fetcher is! PixaRuntimeDescriptor) {
    throw StateError(
      'Pixa video-frame backend "${fetcher.id}" must use the runtime ABI.',
    );
  }
  if (!normalizedKinds.every(_isVideoFrameSourceKind)) {
    throw StateError(
      'Pixa video-frame backend "${fetcher.id}" must not mix video-frame '
      'routes with other fetcher source kinds.',
    );
  }
  final String expected = _expectedVideoFrameSourceKind(fetcher.backendId);
  if (!normalizedKinds.contains(expected)) {
    throw StateError(
      'Pixa video-frame backend "${fetcher.id}" must claim source kind '
      '"$expected".',
    );
  }
  final PixaVideoFrameBackendCapabilities capabilities = fetcher.capabilities;
  if (!capabilities.hotPathSafe) {
    throw StateError(
      'Pixa video-frame backend "${fetcher.id}" must be stable, support at '
      'least one locator and frame selection mode, and declare encoded output.',
    );
  }
  for (final String mimeType in capabilities.outputMimeTypes) {
    final String normalized = _normalizeMimeType(mimeType);
    if (normalized.isEmpty ||
        pixaImageFormatDescriptorForMimeType(normalized) == null) {
      throw StateError(
        'Pixa video-frame backend "${fetcher.id}" declares unsupported '
        'output MIME type "$mimeType".',
      );
    }
  }
}

bool _isVideoFrameSourceKind(String sourceKind) {
  return sourceKind == 'video-frame' || sourceKind.startsWith('video-frame:');
}

String _expectedVideoFrameSourceKind(String? backendId) {
  final String? normalized = _normalizeOptionalRouteClaim(backendId);
  return normalized == null ? 'video-frame' : 'video-frame:$normalized';
}

void _putUnique<T extends PixaRegistryHandler>(
  Map<String, T> handlers,
  T handler,
  String label,
) {
  final String id = handler.id.trim();
  if (id.isEmpty) {
    throw StateError('Pixa $label id must not be empty.');
  }
  if (handlers.containsKey(id)) {
    throw StateError('Duplicate Pixa $label id "$id".');
  }
  handlers[id] = handler;
}

void _validateExecutionContract(
  PixaRegistryHandler handler,
  PixaPluginExecutionKind kind,
  String label,
) {
  if (kind == PixaPluginExecutionKind.runtime &&
      handler is! PixaRuntimeDescriptor) {
    throw StateError(
      'Pixa $label "${handler.id}" declares runtime execution without a '
      'runtime contract.',
    );
  }
  if (kind == PixaPluginExecutionKind.runtime) {
    _validateRuntimeContract(
      (handler as PixaRuntimeDescriptor).runtime,
      label,
      handler.id,
    );
  }
  if (kind == PixaPluginExecutionKind.dart &&
      !_hasDartExecutionHandler(handler, label)) {
    throw StateError(
      'Pixa $label "${handler.id}" declares dart execution without a Dart '
      'handler contract.',
    );
  }
}

bool _hasDartExecutionHandler(PixaRegistryHandler handler, String label) {
  return switch (label) {
    'fetcher' => handler is PixaDartFetcherDescriptor,
    'decoder' => handler is PixaDartDecoderDescriptor,
    'processor' => handler is PixaDartProcessorDescriptor,
    'cache store' => handler is PixaDartCacheStoreDescriptor,
    _ => true,
  };
}

PixaPluginExecutionKind _executionKindFor(PixaRegistryHandler handler) {
  return switch (handler) {
    PixaFetcherDescriptor(:final executionKind) => executionKind,
    PixaDecoderDescriptor(:final executionKind) => executionKind,
    PixaProcessorDescriptor(:final executionKind) => executionKind,
    PixaCacheStoreDescriptor(:final executionKind) => executionKind,
    _ => PixaPluginExecutionKind.dart,
  };
}

void _validateRuntimeContract(
  PixaRuntimeContract contract,
  String label,
  String handlerId,
) {
  if (contract.abiVersion <= 0) {
    throw StateError(
      'Pixa $label "$handlerId" declares an invalid runtime ABI version.',
    );
  }
  if (contract.moduleId.trim().isEmpty) {
    throw StateError(
      'Pixa $label "$handlerId" declares an empty runtime module id.',
    );
  }
  if (!contract.hostManagedRuntime ||
      !contract.binaryMessages ||
      !contract.ownedBuffers ||
      !contract.streamHandles) {
    throw StateError(
      'Pixa $label "$handlerId" must use the Pixa host runtime, binary '
      'messages, owned buffers and stream handles.',
    );
  }
  switch (contract.deployment) {
    case PixaRuntimeDeployment.builtInHostModule:
      break;
    case PixaRuntimeDeployment.hostLinkedPluginModule:
      final String? symbol = contract.entrypointSymbol;
      if (symbol == null || symbol.trim().isEmpty) {
        throw StateError(
          'Pixa $label "$handlerId" host-linked runtime module requires an '
          'entrypoint symbol.',
        );
      }
    case PixaRuntimeDeployment.assetModule:
      final String? assetId = contract.assetId;
      final String? symbol = contract.entrypointSymbol;
      if (assetId == null || assetId.trim().isEmpty) {
        throw StateError(
          'Pixa $label "$handlerId" asset module requires an asset id.',
        );
      }
      if (symbol == null || symbol.trim().isEmpty) {
        throw StateError(
          'Pixa $label "$handlerId" asset module requires an entrypoint '
          'symbol.',
        );
      }
  }
}

void _claim(
  Map<String, String> claims,
  String rawKey,
  String ownerId,
  String label,
) {
  final String key = rawKey.trim().toLowerCase();
  if (key.isEmpty) {
    throw StateError('Pixa $label claim must not be empty.');
  }
  final String? existing = claims[key];
  if (existing != null && existing != ownerId) {
    throw StateError(
      'Pixa $label "$rawKey" is already registered by "$existing".',
    );
  }
  claims[key] = ownerId;
}

String _normalizeMimeType(String mimeType) {
  return mimeType.split(';').first.trim().toLowerCase();
}

String _normalizeRouteClaim(String value) {
  return value.trim().toLowerCase();
}

String? _normalizeOptionalRouteClaim(String? value) {
  final String? normalized = value?.trim().toLowerCase();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

extension on String {
  String? get ifNotEmpty => isEmpty ? null : this;
}

String _hexBytes(List<int> bytes) {
  final StringBuffer buffer = StringBuffer();
  for (final int byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
