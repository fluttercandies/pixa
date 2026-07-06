import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'pixa.dart';
import 'request.dart';

/// Builds a request for an item index.
typedef PixaIndexedRequestBuilder = PixaRequest? Function(int index);

/// Runs one prefetch operation.
typedef PixaPrefetchRunner =
    Future<void> Function(
      PixaRequest request, {
      required PixaPrefetchTarget target,
    });

/// Queue snapshot for predictive prefetch debug surfaces and benchmarks.
final class PixaPredictivePrefetcherSnapshot {
  /// Creates a predictive prefetch snapshot.
  const PixaPredictivePrefetcherSnapshot({
    required this.generation,
    required this.active,
    required this.inFlight,
    required this.pending,
    required this.currentPending,
    required this.stalePending,
    required this.recent,
    required this.skippedPending,
  });

  /// Current viewport generation.
  final int generation;

  /// Active prefetch operations.
  final int active;

  /// In-flight dedupe keys.
  final int inFlight;

  /// Pending queued operations.
  final int pending;

  /// Pending operations that belong to the current generation.
  final int currentPending;

  /// Pending operations retained from older generations.
  final int stalePending;

  /// Recently completed dedupe keys.
  final int recent;

  /// Pending operations skipped because a newer viewport superseded them.
  final int skippedPending;

  /// JSON-like representation for debug UIs.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'generation': generation,
      'active': active,
      'inFlight': inFlight,
      'pending': pending,
      'currentPending': currentPending,
      'stalePending': stalePending,
      'recent': recent,
      'skippedPending': skippedPending,
    };
  }
}

/// Component-agnostic predictive prefetcher for scrollable galleries.
final class PixaPredictivePrefetcher {
  /// Creates a predictive prefetcher.
  PixaPredictivePrefetcher({
    required this.requestBuilder,
    this.target = PixaPrefetchTarget.diskOnly,
    this.forwardItemCount = 12,
    this.backwardItemCount = 2,
    this.maxConcurrent = 2,
    this.recentCapacity = 256,
    PixaPrefetchRunner? runPrefetch,
  }) : assert(forwardItemCount >= 0),
       assert(backwardItemCount >= 0),
       assert(maxConcurrent > 0),
       assert(recentCapacity >= 0),
       _runPrefetch = runPrefetch;

  /// Creates requests for item indexes.
  final PixaIndexedRequestBuilder requestBuilder;

  /// Cache target used by default.
  final PixaPrefetchTarget target;

  /// Number of items to prefetch after the visible range.
  final int forwardItemCount;

  /// Number of items to prefetch before the visible range.
  final int backwardItemCount;

  /// Maximum concurrent prefetch operations owned by this prefetcher.
  final int maxConcurrent;

  /// Number of completed cache keys remembered for dedupe.
  final int recentCapacity;

  final PixaPrefetchRunner? _runPrefetch;
  final Set<String> _inFlight = <String>{};
  final Set<String> _pendingKeys = <String>{};
  final LinkedHashSet<String> _recent = LinkedHashSet<String>();
  final ListQueue<_QueuedPrefetch> _pending = ListQueue<_QueuedPrefetch>();
  _PrefetchBatch? _pendingBatch;
  int _active = 0;
  int _generation = 0;
  int _skippedPending = 0;

  /// Captures current queue state for debug surfaces and benchmarks.
  PixaPredictivePrefetcherSnapshot snapshot() {
    return PixaPredictivePrefetcherSnapshot(
      generation: _generation,
      active: _active,
      inFlight: _inFlight.length,
      pending: _pending.length,
      currentPending: _pending.length,
      stalePending: 0,
      recent: _recent.length,
      skippedPending: _skippedPending,
    );
  }

  /// Prefetches around a visible index range.
  Future<void> prefetchAround({
    required int firstVisibleIndex,
    required int lastVisibleIndex,
    required int itemCount,
    PixaPrefetchTarget? target,
    BuildContext? context,
  }) async {
    if (itemCount < 0) {
      throw ArgumentError.value(itemCount, 'itemCount', 'must not be negative');
    }
    if (firstVisibleIndex > lastVisibleIndex) {
      throw ArgumentError.value(
        firstVisibleIndex,
        'firstVisibleIndex',
        'must be <= lastVisibleIndex',
      );
    }
    if (itemCount == 0 ||
        lastVisibleIndex < 0 ||
        firstVisibleIndex >= itemCount) {
      return;
    }

    final int first = firstVisibleIndex.clamp(0, itemCount - 1).toInt();
    final int last = lastVisibleIndex.clamp(0, itemCount - 1).toInt();
    final PixaPrefetchTarget effectiveTarget = target ?? this.target;
    if (_pending.isEmpty) {
      final List<PixaRequest> requests = _plannedRequests(
        first,
        last,
        itemCount,
        effectiveTarget,
      );
      if (requests.isEmpty) {
        return;
      }
      final int generation = ++_generation;
      return _enqueueBatch(requests, effectiveTarget, context, generation);
    }
    final int generation = ++_generation;
    _discardPendingFromPreviousGeneration();
    final List<PixaRequest> requests = _plannedRequests(
      first,
      last,
      itemCount,
      effectiveTarget,
    );
    if (requests.isEmpty) {
      return;
    }
    return _enqueueBatch(requests, effectiveTarget, context, generation);
  }

  /// Clears in-memory dedupe history. Does not cancel active operations.
  void clearHistory() {
    _recent.clear();
  }

  List<PixaRequest> _plannedRequests(
    int first,
    int last,
    int itemCount,
    PixaPrefetchTarget target,
  ) {
    final Set<String> scheduled = <String>{};
    final List<PixaRequest> requests = <PixaRequest>[];
    for (final int index in _plannedIndexes(first, last, itemCount)) {
      final PixaRequest? request = requestBuilder(index);
      if (request == null) {
        continue;
      }
      final String key = _dedupeKeyFor(request, target);
      if (_inFlight.contains(key) ||
          _pendingKeys.contains(key) ||
          _recent.contains(key) ||
          !scheduled.add(key)) {
        continue;
      }
      requests.add(request);
    }
    return requests;
  }

  Iterable<int> _plannedIndexes(int first, int last, int itemCount) sync* {
    final int forwardEnd = math.min(
      itemCount - 1,
      last.saturatingAdd(forwardItemCount),
    );
    for (int index = last + 1; index <= forwardEnd; index++) {
      yield index;
    }

    final int backwardEnd = math.max(0, first - backwardItemCount);
    for (int index = first - 1; index >= backwardEnd; index--) {
      yield index;
    }
  }

  Future<void> _enqueueBatch(
    List<PixaRequest> requests,
    PixaPrefetchTarget target,
    BuildContext? context,
    int generation,
  ) {
    final _PrefetchBatch batch = _PrefetchBatch(requests.length);
    _pendingBatch = batch;
    for (final PixaRequest request in requests) {
      final String key = _dedupeKeyFor(request, target);
      _pendingKeys.add(key);
      _pending.add(
        _QueuedPrefetch(
          request: request,
          key: key,
          target: target,
          context: context,
          generation: generation,
          batch: batch,
        ),
      );
    }
    _pumpQueue();
    return batch.future;
  }

  void _pumpQueue() {
    while (_active < maxConcurrent && _pending.isNotEmpty) {
      final _QueuedPrefetch work = _pending.removeFirst();
      _pendingKeys.remove(work.key);
      if (_pending.isEmpty) {
        _pendingBatch = null;
      }
      _active++;
      _inFlight.add(work.key);
      unawaited(_runWork(work));
    }
  }

  Future<void> _runWork(_QueuedPrefetch work) async {
    var completed = false;
    try {
      await _run(work.request, work.target, work.context);
      completed = true;
      if (work.generation == _generation) {
        _remember(work.key);
        work.batch.completeOne();
      } else {
        work.batch.completeSkipped(1);
      }
    } on Object catch (error, stackTrace) {
      if (work.generation == _generation) {
        work.batch.completeOne(error: error, stackTrace: stackTrace);
      } else {
        work.batch.completeSkipped(1);
      }
    } finally {
      _inFlight.remove(work.key);
      _active--;
      if (!completed && work.generation != _generation) {
        _recent.remove(work.key);
      }
      _pumpQueue();
    }
  }

  void _discardPendingFromPreviousGeneration() {
    if (_pending.isEmpty) {
      return;
    }
    final int skipped = _pending.length;
    _pendingBatch?.completeSkipped(skipped);
    _skippedPending += skipped;
    _pending.clear();
    _pendingKeys.clear();
    _pendingBatch = null;
  }

  Future<void> _run(
    PixaRequest request,
    PixaPrefetchTarget target,
    BuildContext? context,
  ) {
    final PixaPrefetchRunner? runner = _runPrefetch;
    if (runner != null) {
      return runner(request, target: target);
    }
    return Pixa.prefetch(request, target: target, context: context);
  }

  void _remember(String key) {
    if (recentCapacity == 0) {
      return;
    }
    if (!_recent.add(key)) {
      _recent.remove(key);
      _recent.add(key);
    }
    while (_recent.length > recentCapacity) {
      _recent.remove(_recent.first);
    }
  }

  String _dedupeKeyFor(PixaRequest request, PixaPrefetchTarget target) {
    return switch (target) {
      PixaPrefetchTarget.diskOnly ||
      PixaPrefetchTarget.encodedMemory => request.encodedCacheKey.value,
      PixaPrefetchTarget.decodedPrewarm => request.cacheKey.value,
    };
  }
}

final class _QueuedPrefetch {
  const _QueuedPrefetch({
    required this.request,
    required this.key,
    required this.target,
    required this.context,
    required this.generation,
    required this.batch,
  });

  final PixaRequest request;
  final String key;
  final PixaPrefetchTarget target;
  final BuildContext? context;
  final int generation;
  final _PrefetchBatch batch;
}

final class _PrefetchBatch {
  _PrefetchBatch(this._remaining);

  final Completer<void> _completer = Completer<void>();
  int _remaining;
  Object? _firstError;
  StackTrace? _firstStackTrace;

  Future<void> get future => _completer.future;

  void completeSkipped(int count) {
    if (count <= 0 || _completer.isCompleted) {
      return;
    }
    _remaining -= count;
    _finishIfComplete();
  }

  void completeOne({Object? error, StackTrace? stackTrace}) {
    _firstError ??= error;
    _firstStackTrace ??= stackTrace;
    _complete();
  }

  void _complete() {
    if (_completer.isCompleted) {
      return;
    }
    _remaining--;
    _finishIfComplete();
  }

  void _finishIfComplete() {
    if (_remaining > 0) {
      return;
    }
    if (_firstError != null) {
      _completer.completeError(_firstError!, _firstStackTrace);
      return;
    }
    _completer.complete();
  }
}

extension on int {
  int saturatingAdd(int value) {
    final int result = this + value;
    if (result < this) {
      return 0x7fffffffffffffff;
    }
    return result;
  }
}
