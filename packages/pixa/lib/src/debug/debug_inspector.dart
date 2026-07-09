import '../cache/cache_stats.dart';
import '../config.dart';
import '../display_decoder.dart';
import '../runtime/capabilities.dart';
import '../pixa.dart';
import '../redaction.dart';
import '../registry.dart';
import '../scheduler_stats.dart';

/// Debug snapshot for inspector surfaces and diagnostics.
final class PixaDebugSnapshot {
  /// Creates a debug snapshot.
  const PixaDebugSnapshot({
    required this.isConfigured,
    required this.config,
    required this.displayDecoder,
    required this.capabilities,
    required this.platformSelfCheck,
    required this.registryArchitecture,
    required this.registryRoutePlan,
    required this.cacheStats,
    required this.decodedCacheStats,
    required this.schedulerStats,
  });

  /// Whether Pixa is configured.
  final bool isConfigured;

  /// Current public configuration.
  final PixaConfig config;

  /// Display decoder selector and backend snapshot.
  final PixaDisplayDecoderSnapshot displayDecoder;

  /// runtime capability snapshot.
  final PixaRuntimeCapabilities capabilities;

  /// Runtime platform self-check report.
  final PixaRuntimePlatformSelfCheck platformSelfCheck;

  /// Plugin registry and runtime module architecture snapshot.
  final PixaRegistryArchitectureSnapshot registryArchitecture;

  /// Compiled plugin route plan used by hot-path lookups.
  final Map<String, Object?> registryRoutePlan;

  /// runtime cache statistics, when Pixa is configured.
  final PixaCacheStats? cacheStats;

  /// Flutter decoded image cache statistics.
  final PixaDecodedCacheStats decodedCacheStats;

  /// Scheduler statistics, when Pixa is configured.
  final PixaSchedulerStats? schedulerStats;

  /// JSON-like representation for debug UIs.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'isConfigured': isConfigured,
      'config': <String, Object?>{
        'memoryCacheBytes': config.memoryCacheBytes,
        'diskCacheBytes': config.diskCacheBytes,
        'networkConcurrency': config.networkConcurrency,
        'decodeConcurrency': config.decodeConcurrency,
        'maxImageCompletionsPerFrame': config.maxImageCompletionsPerFrame,
        'maxQueuedRuntimeLoads': config.maxQueuedRuntimeLoads,
        'maxQueuedDecodes': config.maxQueuedDecodes,
        'decodedCacheMaximumSize': config.decodedCacheMaximumSize,
        'decodedCacheMaximumSizeBytes': config.decodedCacheMaximumSizeBytes,
        'hasCustomCacheRoot': config.cacheRootPath != null,
        'pluginCount': config.plugins.length,
        'observerCount': config.observers.length,
        'observerProgressIntervalMicros':
            config.observerSamplingPolicy.progressInterval.inMicroseconds,
        'observerProgressSampleRate':
            config.observerSamplingPolicy.progressSampleRate,
      },
      'displayDecoder': displayDecoder.toJson(),
      'capabilities': <String, Object?>{
        'platform': capabilities.platformStatus.platform,
        'isWeb': capabilities.platformStatus.isWeb,
        'isSupportedPlatform': capabilities.platformStatus.isSupportedPlatform,
        'runtimeAvailable': capabilities.platformStatus.runtimeAvailable,
        'platformMessage': capabilities.platformStatus.message,
        'platformContract': capabilities.platformStatus.contract?.toJson(),
        'diskCache': capabilities.diskCache,
        'httpTransport': capabilities.httpTransport,
        'exifParser': capabilities.exifParser,
        'pixelProcessors': capabilities.pixelProcessors,
        'runtimePluginAbiVersion': capabilities.runtimePluginAbiVersion,
        'runtimePluginRegistryStats': capabilities.runtimePluginRegistryStats
            .toJson(),
        'imageFormats': capabilities.imageFormats
            .map(
              (PixaRuntimeImageFormatCapability capability) =>
                  capability.toJson(),
            )
            .toList(growable: false),
        'platformSelfCheck': platformSelfCheck.toJson(),
      },
      'registryArchitecture': registryArchitecture.toJson(),
      'registryRoutePlan': registryRoutePlan,
      'cacheStats': cacheStats == null
          ? null
          : <String, Object?>{
              'memoryEntries': cacheStats!.memoryEntries,
              'memoryBytes': cacheStats!.memoryBytes,
              'memoryHits': cacheStats!.memoryHits,
              'memoryMisses': cacheStats!.memoryMisses,
              'diskHits': cacheStats!.diskHits,
              'diskMisses': cacheStats!.diskMisses,
              'diskWrites': cacheStats!.diskWrites,
              'diskCorruptionRecoveries': cacheStats!.diskCorruptionRecoveries,
              'evictions': cacheStats!.evictions,
              'hitRate': cacheStats!.hitRate,
              'staleRevalidatesStarted': cacheStats!.staleRevalidatesStarted,
              'staleRevalidatesCompleted':
                  cacheStats!.staleRevalidatesCompleted,
              'staleRevalidatesFailed': cacheStats!.staleRevalidatesFailed,
              'staleRevalidatesSkipped': cacheStats!.staleRevalidatesSkipped,
              'staleRevalidatesInFlight': cacheStats!.staleRevalidatesInFlight,
              'processedMemoryHits': cacheStats!.processedMemoryHits,
              'processedMemoryMisses': cacheStats!.processedMemoryMisses,
              'processedMemoryEvictions': cacheStats!.processedMemoryEvictions,
              'processedDiskHits': cacheStats!.processedDiskHits,
              'processedDiskMisses': cacheStats!.processedDiskMisses,
              'processedDiskStaleHits': cacheStats!.processedDiskStaleHits,
              'processedDiskWrites': cacheStats!.processedDiskWrites,
              'processedDiskCorruptionRecoveries':
                  cacheStats!.processedDiskCorruptionRecoveries,
              'processedHitRate': cacheStats!.processedHitRate,
              'ownedBufferHandlesCreated':
                  cacheStats!.ownedBufferHandlesCreated,
              'ownedBufferHandlesFreed': cacheStats!.ownedBufferHandlesFreed,
              'ownedBufferBytesExposed': cacheStats!.ownedBufferBytesExposed,
              'liveOwnedBufferHandles': cacheStats!.liveOwnedBufferHandles,
              'progressSessionsCreated': cacheStats!.progressSessionsCreated,
              'progressSessionsFreed': cacheStats!.progressSessionsFreed,
              'liveProgressSessions': cacheStats!.liveProgressSessions,
              'progressEventsEmitted': cacheStats!.progressEventsEmitted,
              'progressEventsDropped': cacheStats!.progressEventsDropped,
              'progressEventsDrained': cacheStats!.progressEventsDrained,
            },
      'decodedCacheStats': <String, Object?>{
        'currentSize': decodedCacheStats.currentSize,
        'currentSizeBytes': decodedCacheStats.currentSizeBytes,
        'maximumSize': decodedCacheStats.maximumSize,
        'maximumSizeBytes': decodedCacheStats.maximumSizeBytes,
        'liveImageCount': decodedCacheStats.liveImageCount,
        'byteUtilization': decodedCacheStats.byteUtilization,
      },
      'schedulerStats': schedulerStats?.toJson(),
    };
  }

  /// Compact redacted diagnostic text for issue reports and support logs.
  String toDiagnosticString() {
    final StringBuffer buffer = StringBuffer()
      ..writeln('Pixa diagnostics')
      ..writeln('configured: $isConfigured')
      ..writeln('platform: ${capabilities.platformStatus.platform}')
      ..writeln(
        'runtimeAvailable: ${capabilities.platformStatus.runtimeAvailable}',
      )
      ..writeln('selfCheckPassed: ${platformSelfCheck.passed}')
      ..writeln('displayDecoder: ${displayDecoder.defaultBackend}')
      ..writeln('cacheHitRate: ${_formatRatio(cacheStats?.hitRate ?? 0)}')
      ..writeln(
        'decodedCache: entries=${decodedCacheStats.currentSize}/${decodedCacheStats.maximumSize} '
        'bytes=${decodedCacheStats.currentSizeBytes}/${decodedCacheStats.maximumSizeBytes} '
        'live=${decodedCacheStats.liveImageCount}',
      )
      ..writeln(
        'scheduler: active=${schedulerStats?.activeRuntimeLoads ?? 0} '
        'queue=${schedulerStats?.queueDepth ?? 0} '
        'inflight=${schedulerStats?.inflightRequests ?? 0}',
      )
      ..writeln(
        'handlers: runtime=${registryArchitecture.runtimeHandlers} '
        'dart=${registryArchitecture.dartHandlers} '
        'platform=${registryArchitecture.platformHandlers} '
        'external=${registryArchitecture.externalHandlers}',
      )
      ..writeln(
        'runtimeModules: total=${registryArchitecture.runtimeModules} '
        'singleHost=${registryArchitecture.runtimeCanUseSingleHostBinary}',
      );
    return PixaRedactor.redactText(buffer.toString().trimRight());
  }
}

String _formatRatio(double value) {
  final String fixed = value.toStringAsFixed(3);
  return fixed
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '.0');
}

/// Inspector API for debug tooling.
final class PixaDebugInspector {
  PixaDebugInspector._();

  /// Captures a point-in-time debug snapshot.
  static PixaDebugSnapshot snapshot() {
    final bool configured = Pixa.isConfigured;
    final PixaRuntimeCapabilities capabilities =
        PixaRuntimeCapabilities.current();
    return PixaDebugSnapshot(
      isConfigured: configured,
      config: Pixa.config,
      displayDecoder: pixaDisplayDecoder.snapshot(),
      capabilities: capabilities,
      platformSelfCheck: PixaRuntimePlatformSelfCheck.evaluate(
        capabilities: capabilities,
        cacheRootPath: configured
            ? Pixa.pipeline.cacheRootPath
            : Pixa.config.cacheRootPath,
      ),
      registryArchitecture: configured
          ? Pixa.pipeline.registry.architectureSnapshot()
          : PixaRegistry().architectureSnapshot(),
      registryRoutePlan: configured
          ? Pixa.pipeline.routePlan.toJson()
          : PixaRegistry().compileRoutePlan().toJson(),
      cacheStats: configured ? Pixa.cacheStats() : null,
      decodedCacheStats: Pixa.decodedCacheStats(),
      schedulerStats: configured ? Pixa.pipeline.schedulerStats() : null,
    );
  }
}
