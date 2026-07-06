import 'cache/cache_stats.dart';
import 'failure.dart';
import 'progress.dart';
import 'redaction.dart';
import 'request.dart';

/// Structured event emitted by Pixa.
final class PixaEvent {
  /// Creates a structured observer event.
  factory PixaEvent({
    required int requestId,
    required PixaStage stage,
    required String name,
    PixaRequest? request,
    PixaProgress? progress,
    PixaFailure? failure,
    PixaCacheStats? cacheStats,
    int? timestampMicros,
    int? durationMicros,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) {
    return PixaEvent._(
      requestId: requestId,
      stage: stage,
      name: name,
      request: request == null
          ? null
          : PixaRequestSnapshot.fromRequest(request),
      progress: progress,
      failure: failure,
      cacheStats: cacheStats,
      timestampMicros: timestampMicros ?? DateTime.now().microsecondsSinceEpoch,
      durationMicros: durationMicros,
      attributes: _redactAttributes(attributes),
    );
  }

  const PixaEvent._({
    required this.requestId,
    required this.stage,
    required this.name,
    required this.request,
    required this.progress,
    required this.failure,
    required this.cacheStats,
    required this.timestampMicros,
    required this.durationMicros,
    required this.attributes,
  });

  /// Request id.
  final int requestId;

  /// Pipeline stage.
  final PixaStage stage;

  /// Stable event name.
  final String name;

  /// Redacted related request snapshot.
  final PixaRequestSnapshot? request;

  /// Progress payload.
  final PixaProgress? progress;

  /// Failure payload.
  final PixaFailure? failure;

  /// Cache stats payload.
  final PixaCacheStats? cacheStats;

  /// Wall-clock event timestamp in microseconds since Unix epoch.
  final int timestampMicros;

  /// Monotonic span duration for request-scoped terminal events.
  final int? durationMicros;

  /// Redacted structured attributes.
  final Map<String, Object?> attributes;
}

/// Observer sampling policy for high-frequency event streams.
final class PixaObserverSamplingPolicy {
  /// Creates an observer sampling policy.
  const PixaObserverSamplingPolicy({
    this.progressInterval = Duration.zero,
    this.progressSampleRate = 1,
  }) : assert(progressSampleRate > 0);

  /// No sampling; every event is delivered.
  static const PixaObserverSamplingPolicy none = PixaObserverSamplingPolicy();

  /// Minimum interval between progress events for the same request.
  final Duration progressInterval;

  /// Deliver every Nth progress event after interval filtering.
  final int progressSampleRate;

  /// Whether this policy may drop progress events.
  bool get samplesProgress {
    return progressInterval > Duration.zero || progressSampleRate > 1;
  }
}

/// Redacted request payload safe for observers, logs, and debug panels.
final class PixaRequestSnapshot {
  /// Creates a redacted request snapshot.
  PixaRequestSnapshot.fromRequest(PixaRequest request)
    : sourceLabel = request.source.safeLabel,
      cacheKey = request.cacheKey.value,
      cacheNamespace = request.cacheNamespace,
      targetWidth = request.targetSize?.width,
      targetHeight = request.targetSize?.height,
      scale = request.scale,
      priority = request.priority.name,
      cacheMode = request.cachePolicy.mode.name,
      retryMode = request.retryPolicy.mode.name,
      maxAttempts = request.retryPolicy.maxAttempts,
      allowCrossHostRedirects = request.redirectPolicy.allowCrossHostRedirects,
      allowHttpsToHttpRedirect = request.redirectPolicy.allowHttpsToHttp,
      headers = PixaRedactor.redactHeaders(request.headers);

  /// Redacted source label.
  final String sourceLabel;

  /// Stable hashed cache key.
  final String cacheKey;

  /// Cache namespace.
  final String cacheNamespace;

  /// Target decode width.
  final int? targetWidth;

  /// Target decode height.
  final int? targetHeight;

  /// Image scale.
  final double scale;

  /// Scheduler priority.
  final String priority;

  /// Cache mode.
  final String cacheMode;

  /// Retry mode.
  final String retryMode;

  /// Maximum retry attempts.
  final int maxAttempts;

  /// Whether cross-host redirects are allowed.
  final bool allowCrossHostRedirects;

  /// Whether HTTPS to HTTP redirects are allowed.
  final bool allowHttpsToHttpRedirect;

  /// Redacted request headers.
  final Map<String, String> headers;

  /// JSON-like representation for logging.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'sourceLabel': sourceLabel,
      'cacheKey': cacheKey,
      'cacheNamespace': cacheNamespace,
      'targetWidth': targetWidth,
      'targetHeight': targetHeight,
      'scale': scale,
      'priority': priority,
      'cacheMode': cacheMode,
      'retryMode': retryMode,
      'maxAttempts': maxAttempts,
      'allowCrossHostRedirects': allowCrossHostRedirects,
      'allowHttpsToHttpRedirect': allowHttpsToHttpRedirect,
      'headers': headers,
    };
  }
}

Map<String, Object?> _redactAttributes(Map<String, Object?> attributes) {
  return attributes.map((String key, Object? value) {
    return MapEntry<String, Object?>(key, _redactAttributeValue(value));
  });
}

Object? _redactAttributeValue(Object? value) {
  return switch (value) {
    String() => PixaRedactor.redactText(value),
    Map() => value.map((Object? key, Object? nested) {
      return MapEntry<Object?, Object?>(key, _redactAttributeValue(nested));
    }),
    Iterable() when value is! String =>
      value.map(_redactAttributeValue).toList(),
    _ => value,
  };
}

/// Observer interface for request, cache, scheduler, runtime, and failure events.
abstract interface class PixaObserver {
  /// Called when an event is emitted.
  void onPixaEvent(PixaEvent event);
}

/// Observer that forwards events to a callback.
final class PixaCallbackObserver implements PixaObserver {
  /// Creates a callback observer.
  const PixaCallbackObserver(this.callback);

  /// Event callback.
  final void Function(PixaEvent event) callback;

  @override
  void onPixaEvent(PixaEvent event) => callback(event);
}
