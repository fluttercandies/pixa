import 'dart:async';
import 'dart:typed_data';

import 'failure.dart';
import 'progress.dart';
import 'request.dart';
import 'source.dart';

/// Emits pipeline progress from plugin handlers.
typedef PixaProgressSink = void Function(PixaProgress progress);

/// Cancellation view passed to plugin handlers.
abstract interface class PixaCancellationSignal {
  /// Whether the caller has cancelled this work.
  bool get isCancellationRequested;

  /// Completes when cancellation is requested.
  Future<void> get whenCancelled;

  /// Throws a typed cancellation failure if cancellation has been requested.
  void throwIfCancellationRequested();
}

/// Immutable execution context shared by plugin handlers.
final class PixaExecutionContext {
  /// Creates an execution context.
  const PixaExecutionContext({
    required this.requestId,
    required this.request,
    required this.cancellationSignal,
    this.onProgress,
  });

  /// Request id scoped to this pipeline execution.
  final int requestId;

  /// Request being executed.
  final PixaRequest request;

  /// Cancellation signal shared by this handler invocation.
  final PixaCancellationSignal cancellationSignal;

  /// Optional progress sink.
  final PixaProgressSink? onProgress;

  /// Emits [progress] if a sink is attached.
  void emit(PixaProgress progress) {
    onProgress?.call(progress);
  }
}

/// Encoded bytes returned by fetchers, decoders, processors, and cache stores.
final class PixaBytePayload {
  /// Creates a byte payload.
  const PixaBytePayload({
    required this.bytes,
    this.mimeType,
    this.metadata = const <String, Object?>{},
  });

  /// Encoded bytes.
  ///
  /// Implementations should return immutable or exclusively-owned data. Large
  /// runtime hot paths should prefer owned buffers outside this Dart
  /// plugin contract.
  final Uint8List bytes;

  /// Optional MIME type.
  final String? mimeType;

  /// Non-sensitive structured metadata.
  final Map<String, Object?> metadata;
}

/// Fetcher execution contract.
abstract interface class PixaFetcher {
  /// Fetches encoded bytes for [source].
  FutureOr<PixaBytePayload> fetch(
    PixaSource source,
    PixaExecutionContext context,
  );
}

/// Decoder execution contract.
abstract interface class PixaDecoder {
  /// Decodes or transcodes [input] for [context].
  FutureOr<PixaBytePayload> decode(
    PixaBytePayload input,
    PixaExecutionContext context,
  );
}

/// Processor execution contract.
abstract interface class PixaProcessor {
  /// Applies one processor operation to [input].
  FutureOr<PixaBytePayload> process(
    PixaBytePayload input,
    PixaProcessorContext context,
  );
}

/// Processor-specific execution context.
final class PixaProcessorContext {
  /// Creates a processor context.
  const PixaProcessorContext({
    required this.execution,
    required this.operation,
    this.arguments = const <String, Object?>{},
  });

  /// Shared execution context.
  final PixaExecutionContext execution;

  /// Stable processor operation.
  final String operation;

  /// Processor arguments.
  final Map<String, Object?> arguments;
}

/// Cache lookup result.
sealed class PixaCacheLookup {
  const PixaCacheLookup();
}

/// Cache hit.
final class PixaCacheHit extends PixaCacheLookup {
  /// Creates a cache hit.
  const PixaCacheHit({required this.payload, required this.isStale});

  /// Cached bytes.
  final PixaBytePayload payload;

  /// Whether the entry is expired but still usable for stale paths.
  final bool isStale;
}

/// Cache miss.
final class PixaCacheMiss extends PixaCacheLookup {
  /// Creates a cache miss.
  const PixaCacheMiss();
}

/// Cache-store execution contract.
abstract interface class PixaCacheStore {
  /// Reads one entry.
  FutureOr<PixaCacheLookup> read(
    String namespace,
    String key,
    PixaExecutionContext context,
  );

  /// Writes one entry.
  FutureOr<void> write(
    String namespace,
    String key,
    PixaBytePayload payload,
    PixaCacheWriteContext context,
  );

  /// Removes one entry.
  FutureOr<void> remove(String namespace, String key);

  /// Clears one namespace.
  FutureOr<void> clearNamespace(String namespace);
}

/// Cache write context.
final class PixaCacheWriteContext {
  /// Creates a cache write context.
  const PixaCacheWriteContext({
    required this.execution,
    this.ttl,
    this.privateEntry = false,
  });

  /// Shared execution context.
  final PixaExecutionContext execution;

  /// Entry TTL.
  final Duration? ttl;

  /// Whether this entry belongs to a private cache partition.
  final bool privateEntry;
}

/// Scheduler execution contract for plugin-provided queues.
abstract interface class PixaScheduler {
  /// Enqueues [operation] according to [request] priority and limits.
  Future<T> schedule<T>(
    PixaRequest request,
    Future<T> Function(PixaExecutionContext context) operation,
    PixaExecutionContext context,
  );
}

/// Controller lifecycle hook base class for plugins.
abstract class PixaControllerHook {
  /// Called when a controller attaches.
  void onAttach(PixaRequest request) {}

  /// Called when a controller detaches.
  void onDetach(PixaRequest request) {}

  /// Called when visibility changes.
  void onVisibilityChanged(PixaRequest request, {required bool visible}) {}

  /// Called when a controller is disposed.
  void onDispose(PixaRequest request) {}
}

/// Simple cancellation signal for tests and non-runtime plugin handlers.
final class PixaManualCancellationSignal implements PixaCancellationSignal {
  /// Creates a manual cancellation signal.
  PixaManualCancellationSignal();

  final Completer<void> _completer = Completer<void>();

  @override
  bool get isCancellationRequested => _completer.isCompleted;

  @override
  Future<void> get whenCancelled => _completer.future;

  /// Requests cancellation.
  void cancel() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }

  @override
  void throwIfCancellationRequested() {
    if (!isCancellationRequested) {
      return;
    }
    throw PixaFailure(
      requestId: -1,
      stage: PixaStage.cancel,
      safeMessage: 'Pixa work was cancelled.',
      retryability: PixaRetryability.notRetryable,
    );
  }
}
