import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'cache_key.dart';
import 'redaction.dart';
import 'source.dart';

/// Image priority used by the scheduler.
enum PixaPriority {
  /// Off-screen prefetch work.
  low,

  /// Normal visible work.
  normal,

  /// User-blocking visible work.
  high,

  /// Immediate work such as hero images.
  immediate,
}

/// Cache behavior for a request.
enum PixaCacheMode {
  /// Do not read or write Pixa encoded caches.
  noStore,

  /// Use encoded memory cache only.
  memoryOnly,

  /// Use encoded disk cache only.
  diskOnly,

  /// Use encoded memory and disk cache.
  memoryAndDisk,

  /// Read cache only and fail on miss.
  cacheOnly,

  /// Skip cache reads but allow policy-controlled writes.
  networkOnly,

  /// Force refresh from source.
  refresh,

  /// Return stale cache while refreshing in the background.
  staleWhileRevalidate,
}

/// Prefetch destination.
enum PixaPrefetchTarget {
  /// Fetch encoded bytes and retain only the Rust disk cache entry.
  diskOnly,

  /// Fetch encoded bytes and retain only the Rust encoded-memory entry.
  encodedMemory,

  /// Prewarm Flutter's decoded image cache.
  decodedPrewarm,
}

/// Per-request plugin execution boundary.
///
/// The default keeps gallery hot paths inside Pixa's runtime.
/// Dart and external execution must be enabled explicitly for requests that
/// accept those trade-offs.
@immutable
final class PixaPluginExecutionPolicy {
  /// Creates an explicit plugin execution policy.
  const PixaPluginExecutionPolicy({
    this.runtime = true,
    this.dart = false,
    this.external = false,
  }) : assert(runtime || dart || external);

  /// Uses only runtime modules on the hot path.
  const PixaPluginExecutionPolicy.runtimeOnly()
      : runtime = true,
        dart = false,
        external = false;

  /// Prefers runtime modules but permits explicit Dart plugins.
  const PixaPluginExecutionPolicy.runtimeFirstWithDart()
      : runtime = true,
        dart = true,
        external = false;

  /// Allows an external boundary for requests that explicitly opt into it.
  const PixaPluginExecutionPolicy.withExternal({
    this.runtime = true,
    this.dart = false,
  }) : external = true;

  /// Runtime modules may run through the shared Pixa host.
  final bool runtime;

  /// Dart plugin handlers may run for this request.
  final bool dart;

  /// External plugin boundaries may run for this request.
  final bool external;

  /// True for the default production gallery hot path.
  bool get usesRuntimeOnly => runtime && !dart && !external;

  @override
  bool operator ==(Object other) {
    return other is PixaPluginExecutionPolicy &&
        other.runtime == runtime &&
        other.dart == dart &&
        other.external == external;
  }

  @override
  int get hashCode => Object.hash(runtime, dart, external);
}

/// Cache policy attached to a request.
@immutable
final class PixaCachePolicy {
  /// Creates a cache policy.
  const PixaCachePolicy({
    this.mode = PixaCacheMode.memoryAndDisk,
    this.maxAge,
    this.privateDiskCache = false,
  });

  /// Public cache with optional maximum age.
  const PixaCachePolicy.public({Duration? maxAge})
      : this(mode: PixaCacheMode.memoryAndDisk, maxAge: maxAge);

  /// Cache-only policy.
  const PixaCachePolicy.cacheOnly() : this(mode: PixaCacheMode.cacheOnly);

  /// No-store policy.
  const PixaCachePolicy.noStore() : this(mode: PixaCacheMode.noStore);

  /// Selected cache mode.
  final PixaCacheMode mode;

  /// Optional maximum age for encoded entries.
  final Duration? maxAge;

  /// Whether authenticated/private responses may be stored on disk.
  final bool privateDiskCache;

  /// Returns a policy with selected fields changed.
  PixaCachePolicy copyWith({
    PixaCacheMode? mode,
    Duration? maxAge,
    bool? privateDiskCache,
  }) {
    return PixaCachePolicy(
      mode: mode ?? this.mode,
      maxAge: maxAge ?? this.maxAge,
      privateDiskCache: privateDiskCache ?? this.privateDiskCache,
    );
  }

  /// Whether encoded memory cache reads are allowed.
  bool get readMemory {
    return switch (mode) {
      PixaCacheMode.memoryOnly ||
      PixaCacheMode.memoryAndDisk ||
      PixaCacheMode.cacheOnly ||
      PixaCacheMode.staleWhileRevalidate =>
        true,
      _ => false,
    };
  }

  /// Whether encoded disk cache reads are allowed.
  bool get readDisk {
    return switch (mode) {
      PixaCacheMode.diskOnly ||
      PixaCacheMode.memoryAndDisk ||
      PixaCacheMode.cacheOnly ||
      PixaCacheMode.staleWhileRevalidate =>
        true,
      _ => false,
    };
  }

  /// Whether encoded memory cache writes are allowed.
  bool get writeMemory {
    return switch (mode) {
      PixaCacheMode.memoryOnly ||
      PixaCacheMode.memoryAndDisk ||
      PixaCacheMode.networkOnly ||
      PixaCacheMode.refresh ||
      PixaCacheMode.staleWhileRevalidate =>
        true,
      _ => false,
    };
  }

  /// Whether encoded disk cache writes are allowed.
  bool get writeDisk {
    return switch (mode) {
      PixaCacheMode.diskOnly ||
      PixaCacheMode.memoryAndDisk ||
      PixaCacheMode.networkOnly ||
      PixaCacheMode.refresh ||
      PixaCacheMode.staleWhileRevalidate =>
        true,
      _ => false,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is PixaCachePolicy &&
        other.mode == mode &&
        other.maxAge == maxAge &&
        other.privateDiskCache == privateDiskCache;
  }

  @override
  int get hashCode => Object.hash(mode, maxAge, privateDiskCache);
}

/// Retry strategy.
enum PixaRetryMode {
  /// No retry.
  none,

  /// Fixed delay between attempts.
  fixed,

  /// Exponential backoff.
  exponential,
}

/// Retry policy used by fetch and decode stages.
@immutable
final class PixaRetryPolicy {
  /// Creates a retry policy.
  const PixaRetryPolicy({
    this.mode = PixaRetryMode.none,
    this.maxAttempts = 1,
    this.delay = const Duration(milliseconds: 250),
    this.jitter = Duration.zero,
  }) : assert(maxAttempts > 0);

  /// No retry.
  const PixaRetryPolicy.none() : this();

  /// Exponential retry policy.
  const PixaRetryPolicy.exponential({
    int maxAttempts = 3,
    Duration delay = const Duration(milliseconds: 250),
    Duration jitter = const Duration(milliseconds: 100),
  }) : this(
          mode: PixaRetryMode.exponential,
          maxAttempts: maxAttempts,
          delay: delay,
          jitter: jitter,
        );

  /// Retry mode.
  final PixaRetryMode mode;

  /// Maximum attempts including the initial attempt.
  final int maxAttempts;

  /// Base retry delay.
  final Duration delay;

  /// Maximum random jitter added to retry delay.
  final Duration jitter;

  /// Delay before the given one-based attempt.
  Duration delayForAttempt(int attempt) {
    if (mode == PixaRetryMode.none || attempt <= 1) {
      return Duration.zero;
    }
    final int multiplier =
        mode == PixaRetryMode.exponential ? 1 << (attempt - 2) : 1;
    return delay * multiplier;
  }
}

/// Target encoded or decoded size.
@immutable
final class PixaTargetSize {
  /// Creates a target size.
  const PixaTargetSize({this.width, this.height})
      : assert(width == null || width > 0),
        assert(height == null || height > 0);

  /// Creates a target size from a Flutter size.
  factory PixaTargetSize.fromSize(Size size, double devicePixelRatio) {
    return PixaTargetSize(
      width:
          size.width.isFinite ? (size.width * devicePixelRatio).round() : null,
      height: size.height.isFinite
          ? (size.height * devicePixelRatio).round()
          : null,
    );
  }

  /// Target pixel width.
  final int? width;

  /// Target pixel height.
  final int? height;

  /// True when no target dimension is specified.
  bool get isEmpty => width == null && height == null;

  @override
  bool operator ==(Object other) {
    return other is PixaTargetSize &&
        other.width == width &&
        other.height == height;
  }

  @override
  int get hashCode => Object.hash(width, height);
}

/// Limits protecting memory, network, and decoder resources.
@immutable
final class PixaRequestLimits {
  /// Creates request limits.
  const PixaRequestLimits({
    this.maxEncodedBytes = 32 * 1024 * 1024,
    this.maxDecodedPixels = 64 * 1000 * 1000,
    this.maxAnimationFrames = 600,
    this.maxAnimationDuration = const Duration(seconds: 60),
    this.maxProcessorOutputBytes = 64 * 1024 * 1024,
    this.maxRedirects = 5,
    this.timeout = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 10),
    this.idleTimeout = const Duration(seconds: 15),
  });

  /// Maximum encoded byte length.
  final int maxEncodedBytes;

  /// Maximum decoded pixel count.
  final int maxDecodedPixels;

  /// Maximum animation frames.
  final int maxAnimationFrames;

  /// Maximum cumulative animation duration.
  final Duration maxAnimationDuration;

  /// Maximum encoded byte length produced by runtime processors.
  final int maxProcessorOutputBytes;

  /// Maximum network redirects.
  final int maxRedirects;

  /// Overall request timeout.
  final Duration timeout;

  /// Network connection timeout.
  final Duration connectTimeout;

  /// Network idle timeout.
  final Duration idleTimeout;

  @override
  bool operator ==(Object other) {
    return other is PixaRequestLimits &&
        other.maxEncodedBytes == maxEncodedBytes &&
        other.maxDecodedPixels == maxDecodedPixels &&
        other.maxAnimationFrames == maxAnimationFrames &&
        other.maxAnimationDuration == maxAnimationDuration &&
        other.maxProcessorOutputBytes == maxProcessorOutputBytes &&
        other.maxRedirects == maxRedirects &&
        other.timeout == timeout &&
        other.connectTimeout == connectTimeout &&
        other.idleTimeout == idleTimeout;
  }

  @override
  int get hashCode {
    return Object.hash(
      maxEncodedBytes,
      maxDecodedPixels,
      maxAnimationFrames,
      maxAnimationDuration,
      maxProcessorOutputBytes,
      maxRedirects,
      timeout,
      connectTimeout,
      idleTimeout,
    );
  }
}

/// Redirect safety policy for network image requests.
@immutable
final class PixaRedirectPolicy {
  /// Creates a redirect policy.
  const PixaRedirectPolicy({
    this.allowCrossHostRedirects = true,
    this.allowHttpsToHttp = false,
  });

  /// Whether redirects may change host.
  final bool allowCrossHostRedirects;

  /// Whether an HTTPS request may redirect to HTTP.
  final bool allowHttpsToHttp;

  @override
  bool operator ==(Object other) {
    return other is PixaRedirectPolicy &&
        other.allowCrossHostRedirects == allowCrossHostRedirects &&
        other.allowHttpsToHttp == allowHttpsToHttp;
  }

  @override
  int get hashCode => Object.hash(allowCrossHostRedirects, allowHttpsToHttp);
}

/// Header policy for cache-key participation.
@immutable
final class PixaHeadersPolicy {
  /// Creates a header policy.
  const PixaHeadersPolicy({this.varyHeaders = const <String>{}});

  /// Headers allowed to affect cache identity.
  final Set<String> varyHeaders;

  /// Returns redacted key material for selected headers.
  Map<String, Object?> keyMaterial(Map<String, String> headers) {
    final Map<String, Object?> material = <String, Object?>{};
    for (final String name in varyHeaders) {
      final String? value = headers[name] ?? headers[name.toLowerCase()];
      if (value == null) {
        continue;
      }
      material[name.toLowerCase()] =
          PixaRedactor.isSensitiveHeader(name) ? '<sensitive>' : value;
    }
    return material;
  }
}

/// Immutable request consumed by the image pipeline.
@immutable
final class PixaRequest {
  /// Creates an image request.
  const PixaRequest({
    required this.source,
    this.headers = const <String, String>{},
    this.headersPolicy = const PixaHeadersPolicy(),
    this.cacheNamespace = 'default',
    this.targetSize,
    this.scale = 1.0,
    this.fit,
    this.processors = const <String>[],
    this.decoderOptions = const <String, Object?>{},
    this.pluginExecutionPolicy = const PixaPluginExecutionPolicy.runtimeOnly(),
    this.cachePolicy = const PixaCachePolicy(),
    this.priority = PixaPriority.normal,
    this.retryPolicy = const PixaRetryPolicy.none(),
    this.limits = const PixaRequestLimits(),
    this.redirectPolicy = const PixaRedirectPolicy(),
    this.metadata = const <String, Object?>{},
    this.lowRes,
    this.sources = const <PixaSource>[],
  }) : assert(scale > 0);

  /// Creates a network request.
  factory PixaRequest.network(
    String url, {
    Map<String, String> headers = const <String, String>{},
    PixaTargetSize? targetSize,
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaRedirectPolicy redirectPolicy = const PixaRedirectPolicy(),
    Map<String, Object?> decoderOptions = const <String, Object?>{},
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
  }) {
    return PixaRequest(
      source: PixaSource.network(Uri.parse(url)),
      headers: headers,
      targetSize: targetSize,
      decoderOptions: decoderOptions,
      pluginExecutionPolicy: pluginExecutionPolicy,
      cachePolicy: cachePolicy,
      priority: priority,
      retryPolicy: retryPolicy,
      redirectPolicy: redirectPolicy,
    );
  }

  /// Creates a file request.
  factory PixaRequest.file(
    String path, {
    PixaTargetSize? targetSize,
    double scale = 1.0,
    BoxFit? fit,
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    Map<String, Object?> decoderOptions = const <String, Object?>{},
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    PixaRequest? lowRes,
    bool exifThumbnailFirst = false,
  }) {
    return PixaRequest(
      source: PixaSource.file(path),
      targetSize: targetSize,
      scale: scale,
      fit: fit,
      decoderOptions: decoderOptions,
      pluginExecutionPolicy: pluginExecutionPolicy,
      cachePolicy: cachePolicy,
      priority: priority,
      retryPolicy: retryPolicy,
      lowRes: lowRes ??
          (exifThumbnailFirst
              ? PixaRequest.exifThumbnail(
                  path,
                  targetSize: targetSize,
                  cachePolicy: cachePolicy,
                  priority: priority,
                  retryPolicy: retryPolicy,
                  decoderOptions: decoderOptions,
                  pluginExecutionPolicy: pluginExecutionPolicy,
                )
              : null),
    );
  }

  /// Creates a request for an embedded JPEG EXIF thumbnail.
  factory PixaRequest.exifThumbnail(
    String path, {
    PixaTargetSize? targetSize,
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.high,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    Map<String, Object?> decoderOptions = const <String, Object?>{},
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
  }) {
    return PixaRequest(
      source: PixaSource.exifThumbnail(path),
      targetSize: targetSize,
      decoderOptions: decoderOptions,
      pluginExecutionPolicy: pluginExecutionPolicy,
      cachePolicy: cachePolicy,
      priority: priority,
      retryPolicy: retryPolicy,
    );
  }

  /// Primary image source.
  final PixaSource source;

  /// Optional secondary sources for cache-first or multi-source selection.
  final List<PixaSource> sources;

  /// HTTP headers for network requests.
  final Map<String, String> headers;

  /// Policy controlling which headers affect cache identity.
  final PixaHeadersPolicy headersPolicy;

  /// Cache namespace.
  final String cacheNamespace;

  /// Target decode size.
  final PixaTargetSize? targetSize;

  /// Image scale.
  final double scale;

  /// Intended fit.
  final BoxFit? fit;

  /// Stable processor descriptors.
  final List<String> processors;

  /// Stable decoder option material that affects decoded output identity.
  ///
  /// Values should be deterministic scalar/list/map data. These options do not
  /// affect the original encoded byte cache key, so decode variants can still
  /// share the same source fetch and encoded cache entry.
  final Map<String, Object?> decoderOptions;

  /// Which plugin execution layers this request explicitly permits.
  final PixaPluginExecutionPolicy pluginExecutionPolicy;

  /// Cache behavior.
  final PixaCachePolicy cachePolicy;

  /// Scheduler priority.
  final PixaPriority priority;

  /// Retry behavior.
  final PixaRetryPolicy retryPolicy;

  /// Resource limits.
  final PixaRequestLimits limits;

  /// Redirect safety policy.
  final PixaRedirectPolicy redirectPolicy;

  /// Caller metadata that does not affect cache identity.
  final Map<String, Object?> metadata;

  /// Optional low-resolution request displayed before this request.
  final PixaRequest? lowRes;

  /// Stable cache key.
  PixaCacheKey get cacheKey => _pixaRequestCacheKeys[this] ??= _buildCacheKey();

  PixaCacheKey _buildCacheKey() {
    return PixaCacheKey.fromParts(
      <Object?>[
        cacheNamespace,
        source.cacheMaterial,
        sources.map((PixaSource source) => source.cacheMaterial),
        headersPolicy.keyMaterial(headers),
        _privatePartitionMaterial,
        targetSize?.width,
        targetSize?.height,
        scale,
        fit?.name,
        processors,
        decoderOptions,
        pluginExecutionPolicy.runtime,
        pluginExecutionPolicy.dart,
        pluginExecutionPolicy.external,
        redirectPolicy.allowCrossHostRedirects,
        redirectPolicy.allowHttpsToHttp,
      ],
      debugLabel: '${source.safeLabel}#$cacheNamespace',
    );
  }

  /// Stable key for the original encoded bytes before decode-size or processor variants.
  PixaCacheKey get encodedCacheKey =>
      _pixaRequestEncodedCacheKeys[this] ??= _buildEncodedCacheKey();

  PixaCacheKey _buildEncodedCacheKey() {
    return PixaCacheKey.fromParts(
      <Object?>[
        cacheNamespace,
        source.cacheMaterial,
        headersPolicy.keyMaterial(headers),
        _privatePartitionMaterial,
        redirectPolicy.allowCrossHostRedirects,
        redirectPolicy.allowHttpsToHttp,
      ],
      debugLabel: 'encoded:${source.safeLabel}#$cacheNamespace',
    );
  }

  Object get _privatePartitionMaterial {
    return switch (source) {
      PixaNetworkSource(:final uri) =>
        PixaRedactor.privateNetworkPartitionMaterial(uri, headers),
      _ => PixaRedactor.privateHeaderPartitionMaterial(headers),
    };
  }

  /// Copy with selected overrides.
  PixaRequest copyWith({
    PixaSource? source,
    List<PixaSource>? sources,
    Map<String, String>? headers,
    PixaHeadersPolicy? headersPolicy,
    String? cacheNamespace,
    PixaTargetSize? targetSize,
    double? scale,
    BoxFit? fit,
    List<String>? processors,
    Map<String, Object?>? decoderOptions,
    PixaPluginExecutionPolicy? pluginExecutionPolicy,
    PixaCachePolicy? cachePolicy,
    PixaPriority? priority,
    PixaRetryPolicy? retryPolicy,
    PixaRequestLimits? limits,
    PixaRedirectPolicy? redirectPolicy,
    Map<String, Object?>? metadata,
    PixaRequest? lowRes,
  }) {
    return PixaRequest(
      source: source ?? this.source,
      sources: sources ?? this.sources,
      headers: headers ?? this.headers,
      headersPolicy: headersPolicy ?? this.headersPolicy,
      cacheNamespace: cacheNamespace ?? this.cacheNamespace,
      targetSize: targetSize ?? this.targetSize,
      scale: scale ?? this.scale,
      fit: fit ?? this.fit,
      processors: processors ?? this.processors,
      decoderOptions: decoderOptions ?? this.decoderOptions,
      pluginExecutionPolicy:
          pluginExecutionPolicy ?? this.pluginExecutionPolicy,
      cachePolicy: cachePolicy ?? this.cachePolicy,
      priority: priority ?? this.priority,
      retryPolicy: retryPolicy ?? this.retryPolicy,
      limits: limits ?? this.limits,
      redirectPolicy: redirectPolicy ?? this.redirectPolicy,
      metadata: metadata ?? this.metadata,
      lowRes: lowRes ?? this.lowRes,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PixaRequest && other.cacheKey == cacheKey;
  }

  @override
  int get hashCode => cacheKey.hashCode;
}

final Expando<PixaCacheKey> _pixaRequestCacheKeys =
    Expando<PixaCacheKey>('PixaRequest.cacheKey');
final Expando<PixaCacheKey> _pixaRequestEncodedCacheKeys =
    Expando<PixaCacheKey>('PixaRequest.encodedCacheKey');
