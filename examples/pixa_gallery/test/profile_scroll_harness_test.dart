import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa_gallery/performance/profile_scroll_harness.dart';

void main() {
  testWidgets('profile harness accepts a custom request corpus', (
    WidgetTester tester,
  ) async {
    final GlobalKey<ProfileScrollHarnessState> key =
        GlobalKey<ProfileScrollHarnessState>();
    final List<(int, int)> calls = <(int, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileScrollHarness(
          key: key,
          itemCount: 8,
          initiallyLoading: false,
          prefetchEnabled: false,
          requestBuilder: (int index, int generation) {
            calls.add((index, generation));
            return PixaRequest.network('https://example.test/$index');
          },
        ),
      ),
    );

    final PixaRequest request = key.currentState!.requestFor(7);

    expect(request.source.safeLabel, contains('example.test'));
    expect(calls, <(int, int)>[(7, 0)]);
    expect(key.currentState!.prefetchSnapshot.pending, 0);
    expect(key.currentState!.prefetchSnapshot.active, 0);
  });

  testWidgets('profile harness defers loads and separates display rebuilds', (
    WidgetTester tester,
  ) async {
    final GlobalKey<ProfileScrollHarnessState> key =
        GlobalKey<ProfileScrollHarnessState>();
    final List<(int, int)> calls = <(int, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileScrollHarness(
          key: key,
          itemCount: 1,
          initiallyLoading: false,
          prefetchEnabled: false,
          requestBuilder: (int index, int generation) {
            calls.add((index, generation));
            return PixaRequest.network('https://example.test/$index');
          },
        ),
      ),
    );

    final ProfileScrollHarnessState state = key.currentState!;
    expect(calls, isEmpty);
    expect(state.loadingEnabled, isFalse);
    expect(state.prefetchEnabled, isFalse);

    state.requestFor(0);
    state.rebuildSameRequests();
    state.requestFor(0);
    state.beginColdGeneration();
    state.requestFor(0);
    state.setPrefetchEnabled(true);
    state.startLoading();
    state.jumpToFraction(0.5);
    state.stopLoading();

    expect(calls, <(int, int)>[(0, 0), (0, 1)]);
    expect(state.loadingEnabled, isFalse);
    expect(state.prefetchEnabled, isTrue);
  });

  testWidgets(
    'profile harness supersedes predictive prefetch without jumping scroll',
    (WidgetTester tester) async {
      final GlobalKey<ProfileScrollHarnessState> key =
          GlobalKey<ProfileScrollHarnessState>();
      final List<Completer<void>> completions = <Completer<void>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileScrollHarness(
            key: key,
            itemCount: 100,
            initiallyLoading: false,
            prefetchEnabled: false,
            requestBuilder: (int index, int generation) {
              return PixaRequest.network('https://example.test/$index');
            },
            prefetchRunner:
                (PixaRequest request, {required PixaPrefetchTarget target}) {
                  final Completer<void> completer = Completer<void>();
                  completions.add(completer);
                  return completer.future;
                },
          ),
        ),
      );

      final dynamic state = key.currentState!;
      final Future<void> first =
          state.prefetchAround(firstVisibleIndex: 0, lastVisibleIndex: 0)
              as Future<void>;
      await tester.pump();
      final Future<void> second =
          state.prefetchAround(firstVisibleIndex: 70, lastVisibleIndex: 70)
              as Future<void>;

      expect(key.currentState!.prefetchSnapshot.skippedPending, greaterThan(0));
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .pixels,
        0,
      );

      var completed = 0;
      for (var iteration = 0; iteration < 100; iteration += 1) {
        while (completed < completions.length) {
          completions[completed].complete();
          completed += 1;
        }
        await tester.pump();
        final PixaPredictivePrefetcherSnapshot snapshot =
            key.currentState!.prefetchSnapshot;
        if (snapshot.active == 0 && snapshot.pending == 0) {
          break;
        }
      }
      await Future.wait<void>(<Future<void>>[first, second]);
      expect(key.currentState!.prefetchSnapshot.active, 0);
      expect(key.currentState!.prefetchSnapshot.pending, 0);
    },
  );
}
