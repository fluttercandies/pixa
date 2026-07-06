import 'observer.dart';
import 'plugin.dart';

/// Global Pixa configuration.
final class PixaConfig {
  /// Creates a Pixa configuration.
  const PixaConfig({
    this.memoryCacheBytes = 96 * 1024 * 1024,
    this.diskCacheBytes = 512 * 1024 * 1024,
    this.networkConcurrency = 6,
    this.decodeConcurrency = 2,
    this.maxImageCompletionsPerFrame = 4,
    this.maxQueuedRuntimeLoads = 2048,
    this.maxQueuedDecodes = 128,
    this.decodedCacheMaximumSize,
    this.decodedCacheMaximumSizeBytes,
    this.cacheRootPath,
    this.plugins = const <PixaPlugin>[],
    this.observers = const <PixaObserver>[],
    this.observerSamplingPolicy = PixaObserverSamplingPolicy.none,
  });

  /// Rust encoded memory cache budget.
  final int memoryCacheBytes;

  /// Rust disk cache budget.
  final int diskCacheBytes;

  /// Runtime network concurrency budget.
  final int networkConcurrency;

  /// Flutter decode concurrency budget.
  final int decodeConcurrency;

  /// Maximum decoded image completions released to Flutter in one frame.
  final int maxImageCompletionsPerFrame;

  /// Maximum runtime loads allowed to wait behind active runtime work.
  ///
  /// Low-priority work is rejected or shed first when this limit is reached so
  /// rapid gallery scrolling cannot grow an unbounded Dart-side queue.
  final int maxQueuedRuntimeLoads;

  /// Maximum Flutter display decodes allowed to wait behind active decodes.
  final int maxQueuedDecodes;

  /// Optional Flutter decoded image cache entry budget.
  final int? decodedCacheMaximumSize;

  /// Optional Flutter decoded image cache byte budget.
  final int? decodedCacheMaximumSizeBytes;

  /// Optional platform cache root override.
  final String? cacheRootPath;

  /// Plugins registered during configure.
  final List<PixaPlugin> plugins;

  /// Observers registered during configure.
  final List<PixaObserver> observers;

  /// Sampling policy applied before observer delivery.
  final PixaObserverSamplingPolicy observerSamplingPolicy;
}
