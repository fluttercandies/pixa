import 'package:flutter/foundation.dart';

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
      progress: _observerProgress(progress),
      failure: _observerFailure(failure),
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
    return Map<String, Object?>.unmodifiable(<String, Object?>{
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
    });
  }
}

Map<String, Object?> _redactAttributes(Map<String, Object?> attributes) {
  return Map<String, Object?>.unmodifiable(<String, Object?>{
    for (final MapEntry<String, Object?> entry in attributes.entries)
      PixaRedactor.redactText(
        entry.key,
      ): PixaRedactor.isSensitiveFieldName(entry.key)
          ? '<redacted>'
          : _redactAttributeValue(entry.value),
  });
}

Object? _redactAttributeValue(Object? value) {
  return switch (value) {
    null || num() || bool() => value,
    String() => PixaRedactor.redactText(value),
    Uri() => PixaRedactor.redactUri(value).toString(),
    Uint8List() => Uint8List.fromList(value).asUnmodifiableView(),
    Map() => Map<Object?, Object?>.unmodifiable(<Object?, Object?>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        PixaRedactor.redactText(
          entry.key.toString(),
        ): PixaRedactor.isSensitiveFieldName(entry.key.toString())
            ? '<redacted>'
            : _redactAttributeValue(entry.value),
    }),
    Iterable() when value is! String => List<Object?>.unmodifiable(
      value.map(_redactAttributeValue),
    ),
    _ => PixaRedactor.redactText(value.toString()),
  };
}

PixaProgress? _observerProgress(PixaProgress? progress) {
  if (progress == null) {
    return null;
  }
  final PixaProgressivePreview? preview = progress.progressivePreview;
  return PixaProgress(
    requestId: progress.requestId,
    stage: progress.stage,
    receivedBytes: progress.receivedBytes,
    expectedBytes: progress.expectedBytes,
    message: progress.message == null
        ? null
        : PixaRedactor.redactText(progress.message!),
    progressivePreview: preview == null
        ? null
        : PixaProgressivePreview(
            bytes: preview.bytes,
            mimeType: preview.mimeType,
            sequence: preview.sequence,
          ),
  );
}

PixaFailure? _observerFailure(PixaFailure? failure) {
  if (failure == null) {
    return null;
  }
  return PixaFailure(
    requestId: failure.requestId,
    stage: failure.stage,
    safeMessage: failure.safeMessage,
    retryability: failure.retryability,
  );
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

/// Observer that formats redacted single-line logs for local debugging.
final class PixaLogObserver implements PixaObserver {
  /// Creates a log observer.
  const PixaLogObserver([this.write]);

  /// Receives one redacted log line per event.
  final void Function(String line)? write;

  @override
  void onPixaEvent(PixaEvent event) {
    final String line = PixaRedactor.redactText(_formatEvent(event));
    final void Function(String line)? sink = write;
    if (sink == null) {
      debugPrint(line);
      return;
    }
    sink(line);
  }

  String _formatEvent(PixaEvent event) {
    final StringBuffer buffer = StringBuffer()
      ..write('[${event.stage.name}] ${event.name} #${event.requestId}');
    final PixaRequestSnapshot? request = event.request;
    if (request != null) {
      buffer
        ..write(' source=')
        ..write(request.sourceLabel)
        ..write(' cache=')
        ..write(request.cacheKey)
        ..write(' priority=')
        ..write(request.priority);
    }
    final PixaProgress? progress = event.progress;
    if (progress != null) {
      buffer
        ..write(' progress=')
        ..write(progress.receivedBytes ?? '-')
        ..write('/')
        ..write(progress.expectedBytes ?? '-');
    }
    final PixaFailure? failure = event.failure;
    if (failure != null) {
      buffer
        ..write(' failure=')
        ..write(failure.retryability.name)
        ..write(':')
        ..write(failure.safeMessage);
    }
    if (event.durationMicros != null) {
      buffer
        ..write(' durationMicros=')
        ..write(event.durationMicros);
    }
    if (event.attributes.isNotEmpty) {
      buffer
        ..write(' attrs=')
        ..write(event.attributes);
    }
    return buffer.toString();
  }
}
