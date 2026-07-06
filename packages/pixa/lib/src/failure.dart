import 'progress.dart';
import 'redaction.dart';

/// Retry classification for failures.
enum PixaRetryability {
  /// Retrying can recover.
  retryable,

  /// Retrying cannot recover without changing input or environment.
  notRetryable,

  /// Retryability is unknown.
  unknown,
}

/// Typed pipeline failure.
final class PixaFailure implements Exception {
  /// Creates a typed failure.
  PixaFailure({
    required this.requestId,
    required this.stage,
    required String safeMessage,
    required this.retryability,
    this.originalError,
    this.stackTrace,
  }) : safeMessage = PixaRedactor.redactText(safeMessage);

  /// Request id.
  final int requestId;

  /// Failed stage.
  final PixaStage stage;

  /// Redacted message safe for logs and UI.
  final String safeMessage;

  /// Whether retry may recover.
  final PixaRetryability retryability;

  /// Original error object for diagnostics.
  final Object? originalError;

  /// Original stack trace.
  final StackTrace? stackTrace;

  @override
  String toString() => 'PixaFailure($stage, $safeMessage, $retryability)';
}
