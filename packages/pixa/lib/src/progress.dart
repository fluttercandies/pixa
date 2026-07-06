import 'failure.dart';
import 'dart:typed_data';

/// Pipeline stage for progress, failures, and observer events.
enum PixaStage {
  /// Request is being normalized.
  request,

  /// Cache lookup is running.
  cacheLookup,

  /// Network, file, asset, memory, or custom bytes are being fetched.
  fetch,

  /// Encoded bytes are being decoded by Flutter engine.
  decode,

  /// Processor chain is running.
  process,

  /// Encoded or processed bytes are being stored.
  cacheWrite,

  /// Request finished successfully.
  complete,

  /// Request was cancelled.
  cancel,
}

/// Immutable progress event emitted by the Pixa pipeline.
final class PixaProgress {
  /// Creates a progress event.
  const PixaProgress({
    required this.requestId,
    required this.stage,
    this.receivedBytes,
    this.expectedBytes,
    this.message,
    this.progressivePreview,
  });

  /// Request id.
  final int requestId;

  /// Current pipeline stage.
  final PixaStage stage;

  /// Received byte count when available.
  final int? receivedBytes;

  /// Expected byte count when available.
  final int? expectedBytes;

  /// Redacted human-readable message.
  final String? message;

  /// Progressive image preview produced from the same in-flight request.
  final PixaProgressivePreview? progressivePreview;

  /// Completion ratio when byte counts are known.
  double? get fraction {
    final int? expected = expectedBytes;
    final int? received = receivedBytes;
    if (expected == null || expected <= 0 || received == null) {
      return null;
    }
    return received / expected;
  }
}

/// Encoded progressive preview bytes emitted during network loading.
final class PixaProgressivePreview {
  /// Creates a progressive preview.
  PixaProgressivePreview({
    required Uint8List bytes,
    required this.mimeType,
    required this.sequence,
    Object? retainedOwner,
  })  : bytes = bytes.asUnmodifiableView(),
        _retainedOwner = retainedOwner;

  /// Encoded preview bytes.
  final Uint8List bytes;

  /// Preview MIME type.
  final String mimeType;

  /// Monotonic preview sequence for the request.
  final int sequence;

  final Object? _retainedOwner;

  /// Keeps runtime-owned memory alive for [bytes].
  Object? get retainedOwner => _retainedOwner;
}

/// Load state emitted by controllers and widgets.
sealed class PixaLoadState {
  const PixaLoadState();
}

/// Idle state.
final class PixaIdle extends PixaLoadState {
  /// Creates an idle state.
  const PixaIdle();
}

/// Loading state.
final class PixaLoading extends PixaLoadState {
  /// Creates a loading state.
  const PixaLoading({this.progress});

  /// Latest progress.
  final PixaProgress? progress;
}

/// Completed state.
final class PixaCompleted extends PixaLoadState {
  /// Creates a completed state.
  const PixaCompleted();
}

/// Failed state.
final class PixaFailed extends PixaLoadState {
  /// Creates a failed state.
  const PixaFailed(this.failure);

  /// Typed failure.
  final PixaFailure failure;
}

/// Cancelled state.
final class PixaCancelled extends PixaLoadState {
  /// Creates a cancelled state.
  const PixaCancelled();
}
