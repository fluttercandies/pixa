import 'dart:async';

import 'request.dart';

/// Executes one cache warmup entry.
typedef PixaCacheWarmupExecutor =
    FutureOr<void> Function(PixaCacheWarmupEntry entry);

/// One request in a cache warmup manifest.
final class PixaCacheWarmupEntry {
  /// Creates a cache warmup entry.
  const PixaCacheWarmupEntry({
    required this.id,
    required this.request,
    this.target = PixaPrefetchTarget.encodedMemory,
  });

  /// Stable id used in reports.
  final String id;

  /// Request to prefetch.
  final PixaRequest request;

  /// Cache prefetch target.
  final PixaPrefetchTarget target;
}

/// Batch prefetch manifest for app startup and offline warmup.
final class PixaCacheWarmupManifest {
  /// Creates a warmup manifest.
  PixaCacheWarmupManifest(Iterable<PixaCacheWarmupEntry> entries)
    : entries = List<PixaCacheWarmupEntry>.unmodifiable(entries) {
    final Set<String> ids = <String>{};
    for (final PixaCacheWarmupEntry entry in this.entries) {
      if (entry.id.trim().isEmpty) {
        throw StateError('Pixa cache warmup entry id must not be empty.');
      }
      if (!ids.add(entry.id)) {
        throw StateError('Duplicate Pixa cache warmup entry id "${entry.id}".');
      }
    }
  }

  /// Entries in execution order.
  final List<PixaCacheWarmupEntry> entries;

  /// Runs the manifest with [executor].
  Future<PixaCacheWarmupReport> run(
    PixaCacheWarmupExecutor executor, {
    bool continueOnError = true,
  }) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    final List<String> succeededIds = <String>[];
    final List<PixaCacheWarmupFailure> failures = <PixaCacheWarmupFailure>[];
    var stoppedAfterFailure = false;
    for (final PixaCacheWarmupEntry entry in entries) {
      try {
        await executor(entry);
        succeededIds.add(entry.id);
      } on Object catch (error, stackTrace) {
        failures.add(
          PixaCacheWarmupFailure(
            id: entry.id,
            error: error,
            stackTrace: stackTrace,
          ),
        );
        if (!continueOnError) {
          stoppedAfterFailure = true;
          break;
        }
      }
    }
    stopwatch.stop();
    return PixaCacheWarmupReport(
      totalCount: entries.length,
      succeededIds: List<String>.unmodifiable(succeededIds),
      failures: List<PixaCacheWarmupFailure>.unmodifiable(failures),
      stoppedAfterFailure: stoppedAfterFailure,
      duration: stopwatch.elapsed,
    );
  }
}

/// One failed warmup entry.
final class PixaCacheWarmupFailure {
  /// Creates a warmup failure.
  const PixaCacheWarmupFailure({
    required this.id,
    required this.error,
    required this.stackTrace,
  });

  /// Entry id.
  final String id;

  /// Original error.
  final Object error;

  /// Original stack trace.
  final StackTrace stackTrace;
}

/// Summary produced after running a warmup manifest.
final class PixaCacheWarmupReport {
  /// Creates a warmup report.
  const PixaCacheWarmupReport({
    required this.totalCount,
    required this.succeededIds,
    required this.failures,
    required this.stoppedAfterFailure,
    required this.duration,
  });

  /// Number of manifest entries.
  final int totalCount;

  /// Successful entry ids.
  final List<String> succeededIds;

  /// Failed entries.
  final List<PixaCacheWarmupFailure> failures;

  /// Whether execution stopped because `continueOnError` was false.
  final bool stoppedAfterFailure;

  /// Total execution duration.
  final Duration duration;

  /// Number of successful entries.
  int get successCount => succeededIds.length;

  /// Number of failed entries.
  int get failureCount => failures.length;

  /// Whether all entries were warmed.
  bool get isSuccess => failureCount == 0 && successCount == totalCount;
}
