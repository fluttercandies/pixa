import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'cache/cache_stats.dart';
import 'cache/decoded_cache_registry.dart';
import 'cache_warmup.dart';
import 'config.dart';
import 'image_analysis.dart';
import 'runtime/capabilities.dart';
import 'runtime/runtime_abi_validation.dart';
import 'runtime/runtime_bridge.dart';
import 'observer.dart';
import 'pipeline.dart';
import 'plugin.dart';
import 'provider.dart';
import 'registry.dart';
import 'request.dart';

/// Memory trim severity for coordinated Pixa and Flutter cache pressure.
enum PixaMemoryTrimLevel {
  /// Reduce retained memory while keeping active decoded images alive.
  moderate,

  /// Release all possible cached memory, including Flutter live image handles.
  critical,
}

/// Global Pixa entrypoint.
final class Pixa {
  Pixa._();

  /// Current core package version used for plugin compatibility checks.
  static const String version = '1.0.0';

  static PixaConfig _config = const PixaConfig();
  static PixaPipeline? _pipeline;
  static _PixaWidgetsBindingObserver? _bindingObserver;

  /// Current configuration.
  static PixaConfig get config => _config;

  /// Whether Pixa has been configured.
  static bool get isConfigured => _pipeline != null;

  /// Current runtime-backed pipeline.
  static PixaPipeline get pipeline {
    final PixaPipeline? pipeline = _pipeline;
    if (pipeline == null) {
      throw StateError(
        'Pixa.configure must complete before using Pixa.pipeline.',
      );
    }
    return pipeline;
  }

  /// Configures the runtime-backed image pipeline.
  static Future<void> configure([
    PixaConfig config = const PixaConfig(),
  ]) async {
    _validateConfig(config);
    final PixaRegistry registry = _buildPluginRegistry(config.plugins);
    registry.compileRoutePlan();
    final String rootPath = config.cacheRootPath ?? await _defaultCacheRoot();
    final PixaRuntimeCapabilities capabilities =
        PixaRuntimeCapabilities.current();
    if (!capabilities.hasRequiredCore) {
      throw UnsupportedError(capabilities.platformStatus.message);
    }
    final bool configured = PixaRuntimeBridge.configure(
      memoryCacheBytes: config.memoryCacheBytes,
      diskCacheBytes: config.diskCacheBytes,
      networkConcurrency: config.networkConcurrency,
    );
    if (!configured) {
      throw StateError('Pixa runtime core configuration failed.');
    }
    tuneDecodedCache(
      maximumSize: config.decodedCacheMaximumSize,
      maximumSizeBytes: config.decodedCacheMaximumSizeBytes,
    );

    _config = config;
    _pipeline = PixaPipeline(
      cacheRootPath: rootPath,
      registry: registry,
      observers: <PixaObserver>[...config.observers, ...registry.observers],
      observerSamplingPolicy: config.observerSamplingPolicy,
      maxConcurrentRuntimeLoads: config.networkConcurrency,
      maxQueuedRuntimeLoads: config.maxQueuedRuntimeLoads,
    );
    _installBindingObserver();
  }

  /// Configures Pixa with defaults if needed.
  static Future<void> ensureConfigured() async {
    if (!isConfigured) {
      await configure();
    }
  }

  /// Prefetches bytes or decoded images into the requested cache target.
  static Future<void> prefetch(
    PixaRequest request, {
    PixaPrefetchTarget target = PixaPrefetchTarget.encodedMemory,
    BuildContext? context,
    Size? size,
    ImageErrorListener? onError,
  }) async {
    if (target == PixaPrefetchTarget.decodedPrewarm) {
      final BuildContext resolvedContext =
          context ??
          (throw ArgumentError.value(
            context,
            'context',
            'decoded prewarm prefetch requires a BuildContext',
          ));
      await precache(resolvedContext, request, size: size, onError: onError);
      return;
    }
    await ensureConfigured();
    await pipeline.prefetch(request, target: target);
  }

  /// Runs a cache warmup manifest through [prefetch].
  static Future<PixaCacheWarmupReport> warmup(
    PixaCacheWarmupManifest manifest, {
    bool continueOnError = true,
  }) {
    return manifest.run((PixaCacheWarmupEntry entry) {
      return prefetch(entry.request, target: entry.target);
    }, continueOnError: continueOnError);
  }

  /// Loads a request and analyzes its encoded image bytes through the runtime.
  static Future<PixaImageAnalysis> analyze(PixaRequest request) async {
    await ensureConfigured();
    final PixaPipelineLoad load = await pipeline.load(request);
    try {
      return PixaImageAnalysis.parseEncoded(load.bytes);
    } finally {
      load.dispose();
    }
  }

  /// Prewarms Flutter decoded cache for a request.
  static Future<void> precache(
    BuildContext context,
    PixaRequest request, {
    Size? size,
    ImageErrorListener? onError,
  }) {
    return precacheImage(
      PixaProvider(request: pixaDecodedPrewarmRequest(request)),
      context,
      size: size,
      onError: onError,
    );
  }

  /// Evicts encoded and decoded cache entries for one request.
  static Future<void> evict(
    PixaRequest request, {
    bool encoded = true,
    bool decoded = true,
    ImageConfiguration configuration = ImageConfiguration.empty,
  }) async {
    await ensureConfigured();
    if (encoded) {
      pipeline.evictEncoded(request);
    }
    if (decoded) {
      await _evictDecodedRequest(request, configuration);
    }
  }

  /// Clears encoded and decoded cache entries for a namespace.
  static Future<void> clearNamespace(
    String namespace, {
    bool encoded = true,
    bool decoded = true,
  }) async {
    await ensureConfigured();
    if (encoded) {
      pipeline.clearNamespace(namespace);
    }
    if (decoded) {
      _evictDecodedKeys(pixaDecodedCacheRegistry.takeNamespace(namespace));
    }
  }

  /// Clears all Pixa encoded cache entries and Flutter decoded image cache.
  static Future<void> clearCache({
    bool encoded = true,
    bool decoded = true,
  }) async {
    await ensureConfigured();
    if (encoded) {
      pipeline.clearEncodedCache();
    }
    if (decoded) {
      final ImageCache cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();
      pixaDecodedCacheRegistry.clear();
    }
  }

  /// Coordinates memory pressure trimming across Rust and Flutter caches.
  static Future<void> trimMemory({
    PixaMemoryTrimLevel level = PixaMemoryTrimLevel.moderate,
  }) async {
    await ensureConfigured();
    final int targetBytes = switch (level) {
      PixaMemoryTrimLevel.moderate => _config.memoryCacheBytes ~/ 2,
      PixaMemoryTrimLevel.critical => 0,
    };
    pipeline.trimEncodedMemoryToBytes(targetBytes);
    _trimFlutterImageCache(level);
  }

  /// Returns runtime encoded cache stats.
  static PixaCacheStats cacheStats() {
    return pipeline.cacheStats();
  }

  /// Updates Flutter decoded image cache budgets.
  static void tuneDecodedCache({int? maximumSize, int? maximumSizeBytes}) {
    final ImageCache cache = PaintingBinding.instance.imageCache;
    final int? entries = maximumSize;
    final int? bytes = maximumSizeBytes;
    if (entries != null) {
      if (entries < 0) {
        throw RangeError.range(entries, 0, null, 'maximumSize');
      }
      cache.maximumSize = entries;
    }
    if (bytes != null) {
      if (bytes < 0) {
        throw RangeError.range(bytes, 0, null, 'maximumSizeBytes');
      }
      cache.maximumSizeBytes = bytes;
    }
  }

  /// Returns Flutter decoded image cache stats.
  static PixaDecodedCacheStats decodedCacheStats() {
    final ImageCache cache = PaintingBinding.instance.imageCache;
    return PixaDecodedCacheStats(
      currentSize: cache.currentSize,
      currentSizeBytes: cache.currentSizeBytes,
      maximumSize: cache.maximumSize,
      maximumSizeBytes: cache.maximumSizeBytes,
      liveImageCount: cache.liveImageCount,
    );
  }

  static PixaRegistry _buildPluginRegistry(List<PixaPlugin> plugins) {
    final PixaRegistry registry = PixaRegistry();
    final Set<String> pluginIds = <String>{};
    for (final PixaPlugin plugin in plugins) {
      if (!plugin.compatiblePixaVersions.allows(version)) {
        throw StateError(
          'Pixa plugin "${plugin.id}" is not compatible with Pixa $version.',
        );
      }
      if (!pluginIds.add(plugin.id)) {
        throw StateError('Duplicate Pixa plugin id "${plugin.id}".');
      }
      plugin.register(registry);
    }
    return registry;
  }

  static void _validateConfig(PixaConfig config) {
    if (config.memoryCacheBytes < 0) {
      throw RangeError.range(
        config.memoryCacheBytes,
        0,
        null,
        'memoryCacheBytes',
      );
    }
    validatePixaPortableUintPtr(config.memoryCacheBytes, 'memoryCacheBytes');
    if (config.diskCacheBytes < 0) {
      throw RangeError.range(config.diskCacheBytes, 0, null, 'diskCacheBytes');
    }
    validatePixaPortableUintPtr(config.diskCacheBytes, 'diskCacheBytes');
    if (config.networkConcurrency <= 0) {
      throw RangeError.range(
        config.networkConcurrency,
        1,
        null,
        'networkConcurrency',
      );
    }
    validatePixaNetworkConcurrency(
      config.networkConcurrency,
      'networkConcurrency',
    );
    if (config.decodeConcurrency <= 0) {
      throw RangeError.range(
        config.decodeConcurrency,
        1,
        null,
        'decodeConcurrency',
      );
    }
    if (config.maxImageCompletionsPerFrame <= 0) {
      throw RangeError.range(
        config.maxImageCompletionsPerFrame,
        1,
        null,
        'maxImageCompletionsPerFrame',
      );
    }
    if (config.maxQueuedRuntimeLoads < 0) {
      throw RangeError.range(
        config.maxQueuedRuntimeLoads,
        0,
        null,
        'maxQueuedRuntimeLoads',
      );
    }
    if (config.maxQueuedDecodes < 0) {
      throw RangeError.range(
        config.maxQueuedDecodes,
        0,
        null,
        'maxQueuedDecodes',
      );
    }
    final int? decodedCacheMaximumSize = config.decodedCacheMaximumSize;
    if (decodedCacheMaximumSize != null && decodedCacheMaximumSize < 0) {
      throw RangeError.range(
        decodedCacheMaximumSize,
        0,
        null,
        'decodedCacheMaximumSize',
      );
    }
    final int? decodedCacheMaximumSizeBytes =
        config.decodedCacheMaximumSizeBytes;
    if (decodedCacheMaximumSizeBytes != null &&
        decodedCacheMaximumSizeBytes < 0) {
      throw RangeError.range(
        decodedCacheMaximumSizeBytes,
        0,
        null,
        'decodedCacheMaximumSizeBytes',
      );
    }
  }

  static Future<String> _defaultCacheRoot() async {
    try {
      return (await getApplicationCacheDirectory()).path;
    } on Object {
      return (await getTemporaryDirectory()).path;
    }
  }

  static Future<void> _evictDecodedRequest(
    PixaRequest request,
    ImageConfiguration configuration,
  ) async {
    final List<Object> trackedKeys = pixaDecodedCacheRegistry.takeCacheKey(
      request.cacheKey.value,
    );
    if (trackedKeys.isEmpty) {
      await PixaProvider(request: request).evict(configuration: configuration);
      pixaDecodedCacheRegistry.takeCacheKey(request.cacheKey.value);
      return;
    }
    _evictDecodedKeys(trackedKeys);
  }

  static void _evictDecodedKeys(List<Object> keys) {
    final ImageCache cache = PaintingBinding.instance.imageCache;
    for (final Object key in keys) {
      cache.evict(key);
    }
  }

  static void _trimFlutterImageCache(PixaMemoryTrimLevel level) {
    final ImageCache cache = PaintingBinding.instance.imageCache;
    if (level == PixaMemoryTrimLevel.critical) {
      cache.clear();
      cache.clearLiveImages();
      pixaDecodedCacheRegistry.clear();
      return;
    }

    final int previousMaximum = cache.maximumSizeBytes;
    final int targetMaximum = math.max(0, previousMaximum ~/ 2);
    cache.maximumSizeBytes = targetMaximum;
    cache.maximumSizeBytes = previousMaximum;
  }

  static void _installBindingObserver() {
    final WidgetsBinding binding = WidgetsFlutterBinding.ensureInitialized();
    final _PixaWidgetsBindingObserver? existing = _bindingObserver;
    if (existing != null) {
      binding.removeObserver(existing);
    }
    final _PixaWidgetsBindingObserver observer = _PixaWidgetsBindingObserver();
    binding.addObserver(observer);
    _bindingObserver = observer;
  }
}

final class _PixaWidgetsBindingObserver with WidgetsBindingObserver {
  bool _isTrimming = false;

  @override
  void didHaveMemoryPressure() {
    _trim(PixaMemoryTrimLevel.critical);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.detached:
        _trim(PixaMemoryTrimLevel.critical);
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _trim(PixaMemoryTrimLevel.moderate);
        break;
      case AppLifecycleState.resumed:
        break;
    }
  }

  void _trim(PixaMemoryTrimLevel level) {
    if (_isTrimming || !Pixa.isConfigured) {
      return;
    }
    _isTrimming = true;
    unawaited(
      Pixa.trimMemory(level: level).whenComplete(() {
        _isTrimming = false;
      }),
    );
  }
}
