import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:pixa/pixa.dart';

const int profileItemCount = 2000;
const int profileTilePixels = 128;
const String profileCacheNamespace = 'pixa-profile-scroll';

typedef ProfileRequestBuilder = PixaRequest Function(int index, int generation);

/// Deterministic dense-image surface used only by profile acceptance.
class ProfileScrollHarness extends StatefulWidget {
  const ProfileScrollHarness({
    this.origin,
    this.requestBuilder,
    this.prefetchRunner,
    this.prefetchEnabled = true,
    this.initiallyLoading = true,
    this.itemCount = profileItemCount,
    super.key,
  }) : assert((origin == null) != (requestBuilder == null));

  final Uri? origin;
  final ProfileRequestBuilder? requestBuilder;
  final PixaPrefetchRunner? prefetchRunner;
  final bool prefetchEnabled;
  final bool initiallyLoading;
  final int itemCount;

  @override
  State<ProfileScrollHarness> createState() => ProfileScrollHarnessState();
}

class ProfileScrollHarnessState extends State<ProfileScrollHarness> {
  final ScrollController _scrollController = ScrollController();
  late final PixaPredictivePrefetcher _prefetcher;
  late final List<PixaRequest?> _requests;
  final Set<String> _imageFailures = <String>{};
  final Set<String> _prefetchFailures = <String>{};
  late bool _loadingEnabled;
  late bool _prefetchEnabled;
  int _sourceGeneration = 0;
  int _displayGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadingEnabled = widget.initiallyLoading;
    _prefetchEnabled = widget.prefetchEnabled;
    _requests = List<PixaRequest?>.filled(widget.itemCount, null);
    _prefetcher = PixaPredictivePrefetcher(
      requestBuilder: requestFor,
      target: PixaPrefetchTarget.diskOnly,
      forwardItemCount: 24,
      backwardItemCount: 8,
      maxConcurrent: 3,
      recentCapacity: 512,
      runPrefetch: widget.prefetchRunner,
    );
    _scrollController.addListener(_schedulePrefetch);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_schedulePrefetch);
    _scrollController.dispose();
    _prefetcher.clearHistory();
    super.dispose();
  }

  PixaPredictivePrefetcherSnapshot get prefetchSnapshot =>
      _prefetcher.snapshot();

  bool get loadingEnabled => _loadingEnabled;

  bool get prefetchEnabled => _prefetchEnabled;

  List<String> get failures => List<String>.unmodifiable(<String>[
    ..._imageFailures,
    ..._prefetchFailures,
  ]);

  PixaRequest requestFor(int index) {
    final PixaRequest? cached = _requests[index];
    if (cached != null) {
      return cached;
    }
    final ProfileRequestBuilder? requestBuilder = widget.requestBuilder;
    if (requestBuilder != null) {
      final PixaRequest request = requestBuilder(index, _sourceGeneration);
      _requests[index] = request;
      return request;
    }
    final Uri uri = widget.origin!.replace(
      path: '/image/$index',
      queryParameters: <String, String>{'generation': '$_sourceGeneration'},
    );
    final PixaRequest request = PixaRequest(
      source: PixaSource.network(uri),
      cacheNamespace: profileCacheNamespace,
      targetSize: const PixaTargetSize(
        width: profileTilePixels,
        height: profileTilePixels,
      ),
      fit: BoxFit.cover,
      cachePolicy: const PixaCachePolicy.public(maxAge: Duration(hours: 12)),
      priority: PixaPriority.normal,
    );
    _requests[index] = request;
    return request;
  }

  Future<void> waitUntilAttached() async {
    final Stopwatch timeout = Stopwatch()..start();
    while (!_scrollController.hasClients) {
      if (timeout.elapsed > const Duration(seconds: 10)) {
        throw StateError('Profile scroll surface did not attach in time.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  void beginColdGeneration() {
    _sourceGeneration += 1;
    _displayGeneration += 1;
    _requests.fillRange(0, _requests.length, null);
    _imageFailures.clear();
    _prefetchFailures.clear();
    _prefetcher.clearHistory();
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    setState(() {});
  }

  void rebuildSameRequests() {
    _displayGeneration += 1;
    setState(() {});
  }

  void startLoading() {
    if (_loadingEnabled) {
      return;
    }
    _loadingEnabled = true;
    setState(() {});
  }

  void stopLoading() {
    if (!_loadingEnabled) {
      return;
    }
    _loadingEnabled = false;
    setState(() {});
  }

  void setPrefetchEnabled(bool value) {
    if (_prefetchEnabled == value) {
      return;
    }
    _prefetchEnabled = value;
    if (!value) {
      _prefetcher.clearHistory();
    }
  }

  /// Plans predictive prefetch for a measured viewport without moving the UI.
  Future<void> prefetchAround({
    required int firstVisibleIndex,
    required int lastVisibleIndex,
  }) {
    return _prefetcher.prefetchAround(
      firstVisibleIndex: firstVisibleIndex,
      lastVisibleIndex: lastVisibleIndex,
      itemCount: widget.itemCount,
    );
  }

  Future<void> scrollToStart(Duration duration) {
    return _animateTo(0, duration);
  }

  void jumpToStart() {
    if (!_scrollController.hasClients) {
      throw StateError('Profile scroll surface is not attached.');
    }
    _scrollController.jumpTo(0);
  }

  void jumpToFraction(double fraction) {
    if (!_scrollController.hasClients) {
      throw StateError('Profile scroll surface is not attached.');
    }
    _scrollController.jumpTo(
      _scrollController.position.maxScrollExtent * fraction.clamp(0, 1),
    );
  }

  Future<void> scrollToEnd(Duration duration) async {
    await waitUntilAttached();
    return _animateTo(_scrollController.position.maxScrollExtent, duration);
  }

  Future<void> scrollToFraction(double fraction, Duration duration) async {
    await waitUntilAttached();
    final double target =
        _scrollController.position.maxScrollExtent * fraction.clamp(0, 1);
    return _animateTo(target, duration);
  }

  Future<void> _animateTo(double target, Duration duration) async {
    await waitUntilAttached();
    await _scrollController.animateTo(
      target.clamp(
        _scrollController.position.minScrollExtent,
        _scrollController.position.maxScrollExtent,
      ),
      duration: duration,
      curve: Curves.linear,
    );
  }

  void _schedulePrefetch() {
    if (!_prefetchEnabled ||
        !_loadingEnabled ||
        !_scrollController.hasClients ||
        widget.itemCount == 0) {
      return;
    }
    final ScrollPosition position = _scrollController.position;
    final double fraction = position.maxScrollExtent <= 0
        ? 0
        : position.pixels / position.maxScrollExtent;
    final int first = (fraction * (widget.itemCount - 1)).floor();
    final int visible =
        (position.viewportDimension / profileTilePixels).ceil() * 4;
    final int last = (first + visible).clamp(first, widget.itemCount - 1);
    unawaited(
      _prefetcher
          .prefetchAround(
            firstVisibleIndex: first,
            lastVisibleIndex: last,
            itemCount: widget.itemCount,
          )
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              _prefetchFailures.add('$error\n$stackTrace');
            },
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GridView.builder(
        key: const ValueKey<String>('pixa-profile-scroll'),
        controller: _scrollController,
        scrollCacheExtent: const ScrollCacheExtent.pixels(
          profileTilePixels * 2,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 2,
          crossAxisSpacing: 2,
          childAspectRatio: 1,
        ),
        itemCount: widget.itemCount,
        itemBuilder: (BuildContext context, int index) {
          return RepaintBoundary(
            key: ValueKey<String>('profile-$_displayGeneration-$index'),
            child: !_loadingEnabled
                ? const ColoredBox(color: Color(0xFFE5E7EB))
                : PixaImage(
                    request: requestFor(index),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.none,
                    transitionDuration: Duration.zero,
                    placeholder: const PixaPlaceholder.color(Color(0xFFE5E7EB)),
                    errorBuilder:
                        (
                          BuildContext context,
                          PixaFailure failure,
                          VoidCallback retry,
                        ) {
                          _imageFailures.add(
                            '${failure.stage.name}:${failure.safeMessage}',
                          );
                          return const ColoredBox(color: Color(0xFFB91C1C));
                        },
                  ),
          );
        },
      ),
    );
  }
}
