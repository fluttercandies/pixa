import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

void main() {
  test('predictive prefetcher plans forward then backward indexes', () async {
    final List<int> started = <int>[];
    final PixaPredictivePrefetcher prefetcher = PixaPredictivePrefetcher(
      requestBuilder: _requestForIndex,
      forwardItemCount: 3,
      backwardItemCount: 2,
      maxConcurrent: 8,
      runPrefetch: (PixaRequest request, {required PixaPrefetchTarget target}) {
        started.add(_indexFromRequest(request));
        return Future<void>.value();
      },
    );

    await prefetcher.prefetchAround(
      firstVisibleIndex: 10,
      lastVisibleIndex: 12,
      itemCount: 20,
    );

    expect(started, <int>[13, 14, 15, 9, 8]);
  });

  test('predictive prefetcher respects concurrency cap', () async {
    int active = 0;
    int maxActive = 0;
    final List<Completer<void>> completions = <Completer<void>>[];
    final PixaPredictivePrefetcher prefetcher = PixaPredictivePrefetcher(
      requestBuilder: _requestForIndex,
      forwardItemCount: 4,
      backwardItemCount: 0,
      maxConcurrent: 2,
      runPrefetch: (PixaRequest request, {required PixaPrefetchTarget target}) {
        active++;
        maxActive = active > maxActive ? active : maxActive;
        final Completer<void> completer = Completer<void>();
        completions.add(completer);
        return completer.future.whenComplete(() {
          active--;
        });
      },
    );

    final Future<void> pending = prefetcher.prefetchAround(
      firstVisibleIndex: 0,
      lastVisibleIndex: 0,
      itemCount: 10,
    );

    await Future<void>.delayed(Duration.zero);
    expect(completions, hasLength(2));
    completions.removeAt(0).complete();
    await Future<void>.delayed(Duration.zero);
    expect(completions, hasLength(2));
    completions.removeAt(0).complete();
    await Future<void>.delayed(Duration.zero);
    expect(completions, hasLength(2));
    for (final Completer<void> completion in List<Completer<void>>.of(
      completions,
    )) {
      completion.complete();
    }
    await pending;

    expect(maxActive, 2);
  });

  test(
    'predictive prefetcher keeps concurrency capped across overlapping calls',
    () async {
      int active = 0;
      int maxActive = 0;
      final Map<int, Completer<void>> completions = <int, Completer<void>>{};
      final PixaPredictivePrefetcher prefetcher = PixaPredictivePrefetcher(
        requestBuilder: _requestForIndex,
        forwardItemCount: 4,
        backwardItemCount: 0,
        maxConcurrent: 2,
        runPrefetch:
            (PixaRequest request, {required PixaPrefetchTarget target}) {
              active++;
              maxActive = active > maxActive ? active : maxActive;
              final int index = _indexFromRequest(request);
              final Completer<void> completer = Completer<void>();
              completions[index] = completer;
              return completer.future.whenComplete(() {
                active--;
              });
            },
      );
      final Future<void> first = prefetcher.prefetchAround(
        firstVisibleIndex: 0,
        lastVisibleIndex: 0,
        itemCount: 20,
      );
      await Future<void>.delayed(Duration.zero);
      expect(completions.keys, containsAll(<int>[1, 2]));

      final Future<void> second = prefetcher.prefetchAround(
        firstVisibleIndex: 17,
        lastVisibleIndex: 17,
        itemCount: 20,
      );
      await Future<void>.delayed(Duration.zero);
      expect(maxActive, 2);

      completions.remove(1)!.complete();
      completions.remove(2)!.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(maxActive, 2);
      for (final Completer<void> completion in List<Completer<void>>.of(
        completions.values,
      )) {
        completion.complete();
      }
      await second;

      expect(maxActive, 2);
    },
  );

  test(
    'predictive prefetcher drops stale queued requests on rapid scroll',
    () async {
      final List<int> started = <int>[];
      final Map<int, Completer<void>> completions = <int, Completer<void>>{};
      final PixaPredictivePrefetcher prefetcher = PixaPredictivePrefetcher(
        requestBuilder: _requestForIndex,
        forwardItemCount: 3,
        backwardItemCount: 0,
        maxConcurrent: 1,
        runPrefetch:
            (PixaRequest request, {required PixaPrefetchTarget target}) {
              final int index = _indexFromRequest(request);
              started.add(index);
              final Completer<void> completer = Completer<void>();
              completions[index] = completer;
              return completer.future;
            },
      );
      final Future<void> first = prefetcher.prefetchAround(
        firstVisibleIndex: 0,
        lastVisibleIndex: 0,
        itemCount: 20,
      );
      await Future<void>.delayed(Duration.zero);
      expect(started, <int>[1]);

      final Future<void> second = prefetcher.prefetchAround(
        firstVisibleIndex: 10,
        lastVisibleIndex: 10,
        itemCount: 12,
      );
      completions.remove(1)!.complete();
      await first;
      await Future<void>.delayed(Duration.zero);

      expect(started, isNot(contains(2)));
      expect(started, contains(11));
      for (final Completer<void> completion in List<Completer<void>>.of(
        completions.values,
      )) {
        completion.complete();
      }
      await second;
    },
  );

  test(
    'predictive prefetcher retains overlapping pending work for adjacent viewports',
    () async {
      final List<int> built = <int>[];
      final List<int> started = <int>[];
      final Map<int, Completer<void>> completions = <int, Completer<void>>{};
      final PixaPredictivePrefetcher prefetcher = PixaPredictivePrefetcher(
        requestBuilder: (int index) {
          built.add(index);
          return _requestForIndex(index);
        },
        forwardItemCount: 4,
        backwardItemCount: 0,
        maxConcurrent: 1,
        runPrefetch:
            (PixaRequest request, {required PixaPrefetchTarget target}) {
              final int index = _indexFromRequest(request);
              started.add(index);
              final Completer<void> completer = Completer<void>();
              completions[index] = completer;
              return completer.future;
            },
      );
      prefetcher.clearHistory();

      final Future<void> first = prefetcher.prefetchAround(
        firstVisibleIndex: 0,
        lastVisibleIndex: 0,
        itemCount: 20,
      );
      await Future<void>.delayed(Duration.zero);
      expect(started, <int>[1]);

      final Future<void> second = prefetcher.prefetchAround(
        firstVisibleIndex: 1,
        lastVisibleIndex: 1,
        itemCount: 20,
      );

      expect(built, <int>[1, 2, 3, 4]);
      expect(prefetcher.snapshot().skippedPending, 0);

      final Future<void> third = prefetcher.prefetchAround(
        firstVisibleIndex: 2,
        lastVisibleIndex: 2,
        itemCount: 20,
      );

      expect(built, <int>[1, 2, 3, 4, 5, 6]);
      expect(prefetcher.snapshot().skippedPending, 1);

      while (completions.isNotEmpty) {
        final List<int> active = List<int>.of(completions.keys);
        for (final int index in active) {
          completions.remove(index)!.complete();
        }
        await Future<void>.delayed(Duration.zero);
      }
      await Future.wait<void>(<Future<void>>[first, second, third]);

      expect(started, <int>[1, 3, 4, 5, 6]);
    },
  );

  test(
    'predictive prefetcher discards stale pending generations without blocking current work',
    () async {
      final List<int> started = <int>[];
      final Map<int, Completer<void>> completions = <int, Completer<void>>{};
      final PixaPredictivePrefetcher prefetcher = PixaPredictivePrefetcher(
        requestBuilder: _requestForIndex,
        forwardItemCount: 4,
        backwardItemCount: 0,
        maxConcurrent: 1,
        runPrefetch:
            (PixaRequest request, {required PixaPrefetchTarget target}) {
              final int index = _indexFromRequest(request);
              started.add(index);
              final Completer<void> completer = Completer<void>();
              completions[index] = completer;
              return completer.future;
            },
      );

      final Future<void> first = prefetcher.prefetchAround(
        firstVisibleIndex: 0,
        lastVisibleIndex: 0,
        itemCount: 80,
      );
      await Future<void>.delayed(Duration.zero);
      expect(started, <int>[1]);

      final List<Future<void>> staleBatches = <Future<void>>[];
      for (var firstVisible = 10; firstVisible < 30; firstVisible += 1) {
        staleBatches.add(
          prefetcher.prefetchAround(
            firstVisibleIndex: firstVisible,
            lastVisibleIndex: firstVisible,
            itemCount: 80,
          ),
        );
      }

      final PixaPredictivePrefetcherSnapshot snapshot = prefetcher.snapshot();
      expect(snapshot.active, 1);
      expect(snapshot.currentPending, lessThanOrEqualTo(4));
      expect(snapshot.stalePending, 0);
      expect(snapshot.skippedPending, greaterThan(0));
      expect(snapshot.pending, snapshot.currentPending);

      completions.remove(1)!.complete();
      await first;
      await Future<void>.delayed(Duration.zero);

      expect(started, isNot(contains(2)));
      expect(started, contains(30));
      while (completions.isNotEmpty) {
        final List<int> activeIndexes = List<int>.of(completions.keys);
        for (final int index in activeIndexes) {
          completions.remove(index)!.complete();
        }
        await Future<void>.delayed(Duration.zero);
      }
      await Future.wait(staleBatches);
    },
  );

  test(
    'predictive prefetcher skips in-flight and recently completed keys',
    () async {
      final List<int> started = <int>[];
      final Completer<void> firstCompletion = Completer<void>();
      final PixaPredictivePrefetcher prefetcher = PixaPredictivePrefetcher(
        requestBuilder: _requestForIndex,
        forwardItemCount: 1,
        backwardItemCount: 0,
        maxConcurrent: 1,
        runPrefetch:
            (PixaRequest request, {required PixaPrefetchTarget target}) {
              started.add(_indexFromRequest(request));
              return firstCompletion.future;
            },
      );

      final Future<void> first = prefetcher.prefetchAround(
        firstVisibleIndex: 0,
        lastVisibleIndex: 0,
        itemCount: 10,
      );
      await prefetcher.prefetchAround(
        firstVisibleIndex: 0,
        lastVisibleIndex: 0,
        itemCount: 10,
      );
      firstCompletion.complete();
      await first;
      await prefetcher.prefetchAround(
        firstVisibleIndex: 0,
        lastVisibleIndex: 0,
        itemCount: 10,
      );

      expect(started, <int>[1]);
    },
  );

  test(
    'predictive prefetcher does not remember stale active completions',
    () async {
      final List<int> started = <int>[];
      final Map<int, List<Completer<void>>> completions =
          <int, List<Completer<void>>>{};
      final PixaPredictivePrefetcher prefetcher = PixaPredictivePrefetcher(
        requestBuilder: _requestForIndex,
        forwardItemCount: 1,
        backwardItemCount: 0,
        maxConcurrent: 1,
        runPrefetch:
            (PixaRequest request, {required PixaPrefetchTarget target}) {
              final int index = _indexFromRequest(request);
              started.add(index);
              final Completer<void> completer = Completer<void>();
              completions
                  .putIfAbsent(index, () => <Completer<void>>[])
                  .add(completer);
              return completer.future;
            },
      );

      final Future<void> stale = prefetcher.prefetchAround(
        firstVisibleIndex: 0,
        lastVisibleIndex: 0,
        itemCount: 10,
      );
      await Future<void>.delayed(Duration.zero);
      expect(started, <int>[1]);

      final Future<void> current = prefetcher.prefetchAround(
        firstVisibleIndex: 5,
        lastVisibleIndex: 5,
        itemCount: 10,
      );
      completions[1]!.removeAt(0).complete();
      await stale;
      await Future<void>.delayed(Duration.zero);
      expect(started, <int>[1, 6]);

      completions[6]!.removeAt(0).complete();
      await current;

      final Future<void> revisited = prefetcher.prefetchAround(
        firstVisibleIndex: 0,
        lastVisibleIndex: 0,
        itemCount: 10,
      );
      await Future<void>.delayed(Duration.zero);
      expect(started, <int>[1, 6, 1]);
      completions[1]!.removeAt(0).complete();
      await revisited;
    },
  );

  test(
    'encoded predictive prefetch dedupes variants by encoded cache key',
    () async {
      final List<int?> startedWidths = <int?>[];
      final PixaRequest? first = _variantRequestForIndex(1);
      final PixaRequest? second = _variantRequestForIndex(2);
      expect(first!.cacheKey, isNot(second!.cacheKey));
      expect(first.encodedCacheKey, second.encodedCacheKey);

      final PixaPredictivePrefetcher prefetcher = PixaPredictivePrefetcher(
        requestBuilder: _variantRequestForIndex,
        forwardItemCount: 2,
        backwardItemCount: 0,
        maxConcurrent: 8,
        target: PixaPrefetchTarget.diskOnly,
        runPrefetch:
            (PixaRequest request, {required PixaPrefetchTarget target}) {
              startedWidths.add(request.targetSize?.width);
              return Future<void>.value();
            },
      );

      await prefetcher.prefetchAround(
        firstVisibleIndex: 0,
        lastVisibleIndex: 0,
        itemCount: 3,
      );

      expect(startedWidths, <int?>[100]);
    },
  );

  test('decoded predictive prewarm keeps distinct final variants', () async {
    final List<int?> startedWidths = <int?>[];
    final PixaPredictivePrefetcher prefetcher = PixaPredictivePrefetcher(
      requestBuilder: _variantRequestForIndex,
      forwardItemCount: 2,
      backwardItemCount: 0,
      maxConcurrent: 8,
      target: PixaPrefetchTarget.decodedPrewarm,
      runPrefetch: (PixaRequest request, {required PixaPrefetchTarget target}) {
        startedWidths.add(request.targetSize?.width);
        return Future<void>.value();
      },
    );

    await prefetcher.prefetchAround(
      firstVisibleIndex: 0,
      lastVisibleIndex: 0,
      itemCount: 3,
    );

    expect(startedWidths, <int?>[100, 500]);
  });
}

PixaRequest? _requestForIndex(int index) {
  return PixaRequest.network('https://images.example.test/$index.jpg');
}

PixaRequest? _variantRequestForIndex(int index) {
  if (index == 0) {
    return null;
  }
  return PixaRequest.network(
    'https://images.example.test/shared.jpg',
    targetSize: PixaTargetSize(width: index == 1 ? 100 : 500),
  );
}

int _indexFromRequest(PixaRequest request) {
  final PixaNetworkSource source = request.source as PixaNetworkSource;
  return int.parse(source.uri.pathSegments.single.split('.').first);
}
