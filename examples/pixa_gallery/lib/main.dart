import 'dart:async';
import 'dart:math' as math;

import 'package:flexbox_layout/flexbox_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pixa/pixa.dart';

import 'config/image_config.dart';
import 'models/image_post.dart';
import 'sources/image_source_factory.dart';

enum _GalleryLayout { flexRows, masonry, denseGrid }

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Pixa.configure(
    const PixaConfig(
      memoryCacheBytes: 160 * 1024 * 1024,
      diskCacheBytes: 1024 * 1024 * 1024,
      networkConcurrency: 6,
      decodeConcurrency: 2,
      maxImageCompletionsPerFrame: 3,
      maxQueuedRuntimeLoads: 256,
      maxQueuedDecodes: 32,
      decodedCacheMaximumSize: 1200,
      decodedCacheMaximumSizeBytes: 180 * 1024 * 1024,
    ),
  );
  runApp(const PixaGalleryApp());
}

/// Root application for the Pixa gallery example.
final class PixaGalleryApp extends StatelessWidget {
  /// Creates the gallery app.
  const PixaGalleryApp({
    super.key,
    this.initialPosts = const <ImagePost>[],
    this.loadOnStart = true,
  });

  /// Optional posts injected by automated smoke tests.
  final List<ImagePost> initialPosts;

  /// Whether the gallery should fetch the configured public source on start.
  final bool loadOnStart;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pixa Gallery',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF126B5B),
      ),
      home: PixaGalleryHome(
        initialPosts: initialPosts,
        loadOnStart: loadOnStart,
      ),
    );
  }
}

/// Network gallery adapted from the flexbox example for Pixa.
final class PixaGalleryHome extends StatefulWidget {
  /// Creates the gallery home.
  const PixaGalleryHome({
    super.key,
    this.initialPosts = const <ImagePost>[],
    this.loadOnStart = true,
  });

  /// Optional posts injected by automated smoke tests.
  final List<ImagePost> initialPosts;

  /// Whether the gallery should fetch the configured public source on start.
  final bool loadOnStart;

  @override
  State<PixaGalleryHome> createState() => _PixaGalleryHomeState();
}

final class _PixaGalleryHomeState extends State<PixaGalleryHome> {
  final ScrollController _scrollController = ScrollController();
  final List<ImagePost> _posts = <ImagePost>[];
  List<double> _aspectRatios = const <double>[];
  late final PixaPredictivePrefetcher _prefetcher;

  SourceType _selectedSource = ImageConfig.currentSource;
  _GalleryLayout _layout = _GalleryLayout.flexRows;
  bool _isLoading = false;
  bool _hasMore = true;
  int _currentPage = 1;
  String? _error;
  String _status = 'Ready';
  double _targetRowHeight = 180;
  int _lastPrefetchFirst = -1;
  int _lastPrefetchLast = -1;
  double _lastPrefetchPixels = -1;
  DateTime _lastPrefetchAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _prefetcher = PixaPredictivePrefetcher(
      requestBuilder: _requestForIndex,
      target: PixaPrefetchTarget.diskOnly,
      forwardItemCount: 20,
      backwardItemCount: 4,
      maxConcurrent: 2,
    );
    if (widget.initialPosts.isNotEmpty) {
      _posts.addAll(widget.initialPosts);
      _aspectRatios = _posts
          .map((ImagePost post) => post.aspectRatio)
          .toList(growable: false);
      _hasMore = widget.loadOnStart;
      _currentPage = widget.loadOnStart ? 2 : 1;
      _status = '${_posts.length} fixture images';
      unawaited(_prefetchRange(0, math.min(_posts.length - 1, 12)));
    }
    if (widget.loadOnStart) {
      unawaited(_loadPosts(isRefresh: widget.initialPosts.isEmpty));
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pixa Gallery'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Prefetch current window',
            icon: const Icon(Icons.download_for_offline),
            onPressed: () => unawaited(_prefetchVisible()),
          ),
          IconButton(
            tooltip: 'Cache stats',
            icon: const Icon(Icons.query_stats),
            onPressed: _showCacheStats,
          ),
          IconButton(
            tooltip: 'Trim memory',
            icon: const Icon(Icons.memory),
            onPressed: () => unawaited(_trimMemory()),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: NotificationListener<ScrollNotification>(
          onNotification: _handleScroll,
          child: CustomScrollView(
            key: const ValueKey<String>('pixa-gallery-scroll'),
            controller: _scrollController,
            scrollCacheExtent: const ScrollCacheExtent.pixels(320),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: _GalleryHeader(
                  status: _status,
                  selectedSource: _selectedSource,
                  layout: _layout,
                  targetRowHeight: _targetRowHeight,
                  onSourceChanged: _selectSource,
                  onLayoutChanged: (value) {
                    setState(() {
                      _layout = value;
                      _lastPrefetchFirst = -1;
                      _lastPrefetchLast = -1;
                    });
                  },
                  onRowHeightChanged: (double value) {
                    setState(() {
                      _targetRowHeight = value;
                      _lastPrefetchFirst = -1;
                      _lastPrefetchLast = -1;
                    });
                  },
                ),
              ),
              if (_error != null && _posts.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _ErrorState(message: _error!, onRetry: _refresh),
                )
              else if (_posts.isEmpty && _isLoading)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: _LoadingState(),
                )
              else
                _GallerySliver(
                  posts: _posts,
                  aspectRatios: _aspectRatios,
                  layout: _layout,
                  targetRowHeight: _targetRowHeight,
                ),
              SliverToBoxAdapter(
                child: _LoadMoreBar(
                  isLoading: _isLoading,
                  hasMore: _hasMore,
                  onLoadMore: _loadMore,
                ),
              ),
              SliverToBoxAdapter(child: _ScenarioSection(posts: _posts)),
              const SliverToBoxAdapter(child: SizedBox(height: 28)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loadPosts({bool isRefresh = false}) async {
    if (_isLoading || (!isRefresh && !_hasMore)) {
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final int page = isRefresh ? 1 : _currentPage;
      final List<ImagePost> next = await ImageSourceFactory.create(
        _selectedSource,
      ).fetchPosts(page: page, limit: ImageConfig.defaultLimit);
      if (!mounted) {
        return;
      }
      setState(() {
        if (isRefresh) {
          _posts.clear();
          _aspectRatios = const <double>[];
          _currentPage = 1;
          _hasMore = true;
          _lastPrefetchFirst = -1;
          _lastPrefetchLast = -1;
          _lastPrefetchPixels = -1;
          _prefetcher.clearHistory();
        }
        _posts.addAll(next);
        _aspectRatios = _posts
            .map((ImagePost post) => post.aspectRatio)
            .toList(growable: false);
        _currentPage = page + 1;
        _hasMore = next.length == ImageConfig.defaultLimit;
        _isLoading = false;
        _status = '${_posts.length} images from ${_selectedSource.name}';
      });
      await _prefetchRange(0, math.min(_posts.length - 1, 12));
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Load error: $error';
        _isLoading = false;
        _status = _error!;
      });
    }
  }

  Future<void> _refresh() async {
    await _loadPosts(isRefresh: true);
  }

  Future<void> _loadMore() async {
    await _loadPosts();
  }

  void _selectSource(SourceType source) {
    if (source == _selectedSource) {
      return;
    }
    setState(() {
      _selectedSource = source;
      ImageConfig.currentSource = source;
    });
    unawaited(_refresh());
  }

  bool _handleScroll(ScrollNotification notification) {
    final ScrollMetrics metrics = notification.metrics;
    if (metrics.axis != Axis.vertical || _posts.isEmpty) {
      return false;
    }
    final DateTime now = DateTime.now();
    final bool movedEnough =
        _lastPrefetchPixels < 0 ||
        (metrics.pixels - _lastPrefetchPixels).abs() >
            metrics.viewportDimension * 0.22;
    final bool stale =
        now.difference(_lastPrefetchAt) >= const Duration(milliseconds: 220);
    if (movedEnough || stale || notification is ScrollEndNotification) {
      final _VisibleRange range = _estimateVisibleRange(metrics);
      final int first = range.first;
      final int last = range.last;
      _lastPrefetchFirst = first;
      _lastPrefetchLast = last;
      _lastPrefetchPixels = metrics.pixels;
      _lastPrefetchAt = now;
      unawaited(_prefetchRange(first, last));
    }
    if (_hasMore &&
        !_isLoading &&
        metrics.extentAfter < metrics.viewportDimension * 1.8) {
      unawaited(_loadMore());
    }
    return false;
  }

  _VisibleRange _estimateVisibleRange(ScrollMetrics metrics) {
    final double lineExtent = switch (_layout) {
      _GalleryLayout.flexRows => _targetRowHeight + 8,
      _GalleryLayout.masonry => (_targetRowHeight * 1.18).clamp(150, 380),
      _GalleryLayout.denseGrid => (_targetRowHeight * 1.05).clamp(128, 300),
    };
    final int estimatedColumns = switch (_layout) {
      _GalleryLayout.flexRows => 4,
      _GalleryLayout.masonry => 5,
      _GalleryLayout.denseGrid => 6,
    };
    final int firstLine = math.max(0, metrics.pixels ~/ lineExtent);
    final int visibleLines = math.max(
      1,
      (metrics.viewportDimension / lineExtent).ceil() + 2,
    );
    final int first = math.max(0, firstLine * estimatedColumns);
    final int last = math.min(
      _posts.length - 1,
      first + visibleLines * estimatedColumns,
    );
    return _VisibleRange(first: first, last: last);
  }

  Future<void> _prefetchVisible() async {
    final int first = _lastPrefetchFirst < 0 ? 0 : _lastPrefetchFirst;
    final int last = math.min(
      _posts.length - 1,
      _lastPrefetchLast < 0 ? 18 : math.max(first, _lastPrefetchLast),
    );
    await _prefetchRange(first, last, report: true);
  }

  Future<void> _prefetchRange(
    int first,
    int last, {
    bool report = false,
  }) async {
    if (_posts.isEmpty || first > last) {
      return;
    }
    try {
      await _prefetcher.prefetchAround(
        firstVisibleIndex: first,
        lastVisibleIndex: last,
        itemCount: _posts.length,
      );
      if (report && mounted) {
        setState(() {
          _status = 'Prefetched image ${first + 1}-${last + 1}';
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _status = 'Prefetch failed: $error';
        });
      }
    }
  }

  Future<void> _trimMemory() async {
    await Pixa.trimMemory(level: PixaMemoryTrimLevel.moderate);
    if (!mounted) {
      return;
    }
    setState(() {
      _status = 'Encoded and decoded caches trimmed';
    });
  }

  void _showCacheStats() {
    final PixaCacheStats stats = Pixa.cacheStats();
    setState(() {
      _status =
          'Memory ${_formatBytes(stats.memoryBytes)} · '
          '${(stats.hitRate * 100).toStringAsFixed(1)}% hit rate · '
          '${stats.diskWrites} disk writes';
    });
  }

  PixaRequest? _requestForIndex(int index) {
    if (index < 0 || index >= _posts.length) {
      return null;
    }
    return _requestForPost(
      _posts[index],
      targetPixels: switch (_layout) {
        _GalleryLayout.flexRows => (_targetRowHeight * 2.2).round(),
        _GalleryLayout.masonry => (_targetRowHeight * 2.0).round(),
        _GalleryLayout.denseGrid => (_targetRowHeight * 1.65).round(),
      },
    );
  }
}

final class _VisibleRange {
  const _VisibleRange({required this.first, required this.last});

  final int first;
  final int last;
}

final class _GalleryHeader extends StatelessWidget {
  const _GalleryHeader({
    required this.status,
    required this.selectedSource,
    required this.layout,
    required this.targetRowHeight,
    required this.onSourceChanged,
    required this.onLayoutChanged,
    required this.onRowHeightChanged,
  });

  final String status;
  final SourceType selectedSource;
  final _GalleryLayout layout;
  final double targetRowHeight;
  final ValueChanged<SourceType> onSourceChanged;
  final ValueChanged<_GalleryLayout> onLayoutChanged;
  final ValueChanged<double> onRowHeightChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Network image gallery',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            status,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<_GalleryLayout>(
              segments: const <ButtonSegment<_GalleryLayout>>[
                ButtonSegment<_GalleryLayout>(
                  value: _GalleryLayout.flexRows,
                  icon: Icon(Icons.view_stream),
                  label: Text('Flex rows'),
                ),
                ButtonSegment<_GalleryLayout>(
                  value: _GalleryLayout.masonry,
                  icon: Icon(Icons.dashboard_customize),
                  label: Text('Masonry'),
                ),
                ButtonSegment<_GalleryLayout>(
                  value: _GalleryLayout.denseGrid,
                  icon: Icon(Icons.grid_view),
                  label: Text('Grid'),
                ),
              ],
              selected: <_GalleryLayout>{layout},
              showSelectedIcon: false,
              onSelectionChanged: (Set<_GalleryLayout> value) {
                onLayoutChanged(value.single);
              },
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final SourceType source in SourceType.values)
                ChoiceChip(
                  label: Text(source.name),
                  selected: source == selectedSource,
                  onSelected: (_) => onSourceChanged(source),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              const Icon(Icons.view_stream, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Slider(
                  min: 120,
                  max: 320,
                  value: targetRowHeight,
                  label: '${targetRowHeight.round()} px',
                  onChanged: onRowHeightChanged,
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  '${targetRowHeight.round()} px',
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

final class _GallerySliver extends StatelessWidget {
  const _GallerySliver({
    required this.posts,
    required this.aspectRatios,
    required this.layout,
    required this.targetRowHeight,
  });

  final List<ImagePost> posts;
  final List<double> aspectRatios;
  final _GalleryLayout layout;
  final double targetRowHeight;

  @override
  Widget build(BuildContext context) {
    return switch (layout) {
      _GalleryLayout.flexRows => _FlexRowsSliver(
        posts: posts,
        aspectRatios: aspectRatios,
        targetRowHeight: targetRowHeight,
      ),
      _GalleryLayout.masonry => _MasonrySliver(
        posts: posts,
        targetRowHeight: targetRowHeight,
      ),
      _GalleryLayout.denseGrid => _DenseGridSliver(
        posts: posts,
        targetRowHeight: targetRowHeight,
      ),
    };
  }
}

final class _FlexRowsSliver extends StatelessWidget {
  const _FlexRowsSliver({
    required this.posts,
    required this.aspectRatios,
    required this.targetRowHeight,
  });

  final List<ImagePost> posts;
  final List<double> aspectRatios;
  final double targetRowHeight;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      sliver: SliverFlexbox(
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) {
            return _ImageTile(
              key: ValueKey<String>('flex-${posts[index].id}'),
              post: posts[index],
              showLabel: false,
            );
          },
          childCount: posts.length,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: false,
          addSemanticIndexes: false,
        ),
        flexboxDelegate: SliverFlexboxDelegateWithAspectRatios(
          aspectRatios: aspectRatios,
          targetRowHeight: targetRowHeight,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
      ),
    );
  }
}

final class _MasonrySliver extends StatelessWidget {
  const _MasonrySliver({required this.posts, required this.targetRowHeight});

  final List<ImagePost> posts;
  final double targetRowHeight;

  @override
  Widget build(BuildContext context) {
    final double maxCrossAxisExtent = (targetRowHeight * 1.28)
        .clamp(150, 360)
        .toDouble();
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      sliver: SliverMasonryFlexbox(
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) {
            return _ImageTile(
              key: ValueKey<String>('masonry-${posts[index].id}'),
              post: posts[index],
              showLabel: false,
            );
          },
          childCount: posts.length,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: false,
          addSemanticIndexes: false,
        ),
        masonryDelegate: SliverMasonryFlexboxDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: maxCrossAxisExtent,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatioBuilder: (int index) => posts[index].aspectRatio,
        ),
      ),
    );
  }
}

final class _DenseGridSliver extends StatelessWidget {
  const _DenseGridSliver({required this.posts, required this.targetRowHeight});

  final List<ImagePost> posts;
  final double targetRowHeight;

  @override
  Widget build(BuildContext context) {
    final double maxCrossAxisExtent = (targetRowHeight * 1.1)
        .clamp(128, 300)
        .toDouble();
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: maxCrossAxisExtent,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) {
            return _ImageTile(
              key: ValueKey<String>('grid-${posts[index].id}'),
              post: posts[index],
              showLabel: false,
            );
          },
          childCount: posts.length,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: false,
          addSemanticIndexes: false,
        ),
      ),
    );
  }
}

final class _ImageTile extends StatefulWidget {
  const _ImageTile({super.key, required this.post, this.showLabel = true});

  final ImagePost post;
  final bool showLabel;

  @override
  State<_ImageTile> createState() => _ImageTileState();
}

final class _ImageTileState extends State<_ImageTile> {
  PixaRequest? _cachedRequest;
  int? _cachedTargetWidth;
  int? _cachedTargetHeight;
  String? _cachedImageUrl;

  @override
  void didUpdateWidget(_ImageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.imageUrl != widget.post.imageUrl ||
        oldWidget.post.id != widget.post.id) {
      _cachedRequest = null;
      _cachedTargetWidth = null;
      _cachedTargetHeight = null;
      _cachedImageUrl = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: GestureDetector(
        onTap: () => _openLargeImage(context, widget.post),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.hardEdge,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  return PixaImage(
                    request: _requestForTile(context, constraints),
                    fit: BoxFit.cover,
                    placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
                    errorBuilder: _errorBuilder,
                    transitionDuration: Duration.zero,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.none,
                  );
                },
              ),
              if (widget.showLabel)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.56),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      child: Text(
                        '${widget.post.source.name} #${widget.post.id}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0,
                            ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  PixaRequest _requestForTile(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    final double devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final int? targetWidth = _targetDimension(
      constraints.maxWidth,
      devicePixelRatio,
    );
    final int? targetHeight = _targetDimension(
      constraints.maxHeight,
      devicePixelRatio,
    );
    final PixaRequest? request = _cachedRequest;
    if (request != null &&
        _cachedTargetWidth == targetWidth &&
        _cachedTargetHeight == targetHeight &&
        _cachedImageUrl == widget.post.imageUrl) {
      return request;
    }
    final PixaRequest next = _requestForPost(
      widget.post,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    _cachedRequest = next;
    _cachedTargetWidth = targetWidth;
    _cachedTargetHeight = targetHeight;
    _cachedImageUrl = widget.post.imageUrl;
    return next;
  }

  int? _targetDimension(double logicalExtent, double devicePixelRatio) {
    if (!logicalExtent.isFinite || logicalExtent <= 0) {
      return null;
    }
    return (logicalExtent * devicePixelRatio).ceil().clamp(1, 1 << 30).toInt();
  }
}

void _openLargeImage(BuildContext context, ImagePost post) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => _LargeImagePage(post: post),
    ),
  );
}

final class _LargeImagePage extends StatefulWidget {
  const _LargeImagePage({required this.post});

  final ImagePost post;

  @override
  State<_LargeImagePage> createState() => _LargeImagePageState();
}

final class _LargeImagePageState extends State<_LargeImagePage> {
  late final PixaLargeImageController _controller = PixaLargeImageController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ImagePost post = widget.post;
    return Scaffold(
      backgroundColor: const Color(0xFF111318),
      appBar: AppBar(
        title: Text('${post.source.name} #${post.id}'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Fit',
            icon: const Icon(Icons.fit_screen),
            onPressed: _controller.reset,
          ),
          IconButton(
            tooltip: '100%',
            icon: const Icon(Icons.center_focus_strong),
            onPressed: () => _controller.zoomTo(1),
          ),
          IconButton(
            tooltip: '200%',
            icon: const Icon(Icons.zoom_in),
            onPressed: () => _controller.zoomTo(2),
          ),
        ],
      ),
      body: PixaLargeImage(
        request: _requestForPost(post),
        imageWidth: post.width,
        imageHeight: post.height,
        controller: _controller,
        maxScale: 4,
        tileSize: 512,
        cacheExtentScreens: 1.25,
        maxVisibleTiles: 80,
        placeholder: const PixaPlaceholder.color(Color(0xFF1D222B)),
        progressBuilder: _progressBuilder,
        errorBuilder: _errorBuilder,
        tileErrorBuilder: _largeImageTileErrorBuilder,
      ),
    );
  }
}

final class _LoadMoreBar extends StatelessWidget {
  const _LoadMoreBar({
    required this.isLoading,
    required this.hasMore,
    required this.onLoadMore,
  });

  final bool isLoading;
  final bool hasMore;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
      child: Center(
        child: isLoading
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              )
            : OutlinedButton.icon(
                onPressed: hasMore ? onLoadMore : null,
                icon: Icon(hasMore ? Icons.expand_more : Icons.check),
                label: Text(hasMore ? 'Load more' : 'No more images'),
              ),
      ),
    );
  }
}

final class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox.square(
        dimension: 32,
        child: CircularProgressIndicator(strokeWidth: 3),
      ),
    );
  }
}

final class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 44, color: colors.error),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ScenarioSection extends StatelessWidget {
  const _ScenarioSection({required this.posts});

  final List<ImagePost> posts;

  @override
  Widget build(BuildContext context) {
    final ImagePost? first = posts.isEmpty ? null : posts.first;
    final List<_Scenario> scenarios = <_Scenario>[
      if (first != null)
        _Scenario(
          title: 'Provider',
          child: Image(
            image: PixaProvider.network(first.imageUrl),
            fit: BoxFit.cover,
          ),
        ),
      if (first != null)
        _Scenario(
          title: 'Large viewer',
          child: _LargeImagePreview(post: first),
        ),
      if (first != null)
        _Scenario(
          title: 'Low-res chain',
          child: PixaImage(
            request: _requestForPost(
              first,
              targetPixels: 720,
            ).copyWith(lowRes: _thumbnailRequestForPost(first)),
            fit: BoxFit.cover,
            placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
            progressBuilder: _progressBuilder,
            errorBuilder: _errorBuilder,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      if (first != null)
        _Scenario(
          title: 'Processor',
          child: PixaImage(
            request: _requestForPost(
              first,
              targetPixels: 360,
              processors: const <String>[
                'resizeExact(width=360,height=360)',
                'watermark(text=Pixa,position=bottomRight,padding=14,scale=2)',
              ],
            ),
            fit: BoxFit.cover,
            placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
            progressBuilder: _progressBuilder,
            errorBuilder: _errorBuilder,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      if (first != null)
        _Scenario(
          title: 'Cache only',
          child: PixaImage(
            request: _requestForPost(
              first,
              targetPixels: 360,
            ).copyWith(cachePolicy: const PixaCachePolicy.cacheOnly()),
            fit: BoxFit.cover,
            placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
            errorBuilder: _errorBuilder,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      _Scenario(
        title: 'Progressive JPEG',
        child: PixaImage.network(
          'https://raw.githubusercontent.com/sindresorhus/is-progressive/main/fixture/progressive.jpg',
          fit: BoxFit.cover,
          placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
          progressBuilder: _progressBuilder,
          errorBuilder: _errorBuilder,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      _Scenario(
        title: 'Animated GIF',
        child: PixaImage.network(
          'https://media.giphy.com/media/3oEjI6SIIHBdRxXI40/giphy.gif',
          fit: BoxFit.cover,
          placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
          progressBuilder: _progressBuilder,
          errorBuilder: _errorBuilder,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      _Scenario(
        title: 'Animated WebP',
        child: PixaImage.network(
          'https://www.gstatic.com/webp/animated/1.webp',
          fit: BoxFit.cover,
          placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
          progressBuilder: _progressBuilder,
          errorBuilder: _errorBuilder,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      _Scenario(
        title: 'Retry',
        child: PixaImage.network(
          'https://images.example.invalid/missing.jpg',
          fit: BoxFit.cover,
          placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
          errorBuilder: _errorBuilder,
          retryPolicy: const PixaRetryPolicy.exponential(maxAttempts: 2),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    ];
    if (scenarios.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Pixa scenarios',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 210,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: scenarios.length,
              separatorBuilder: (BuildContext context, int index) =>
                  const SizedBox(width: 10),
              itemBuilder: (BuildContext context, int index) {
                return _ScenarioTile(scenario: scenarios[index]);
              },
            ),
          ),
        ],
      ),
    );
  }
}

final class _ScenarioTile extends StatelessWidget {
  const _ScenarioTile({required this.scenario});

  final _Scenario scenario;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 190,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox.expand(
                  child: _ScenarioViewport(child: scenario.child),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            scenario.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

final class _LargeImagePreview extends StatelessWidget {
  const _LargeImagePreview({required this.post});

  final ImagePost post;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _openLargeImage(context, post),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          PixaImage(
            request: _requestForPost(post, targetPixels: 360),
            fit: BoxFit.cover,
            placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
            progressBuilder: _progressBuilder,
            errorBuilder: _errorBuilder,
          ),
          const Positioned(
            right: 8,
            bottom: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0xAA000000),
                borderRadius: BorderRadius.all(Radius.circular(6)),
              ),
              child: Padding(
                padding: EdgeInsets.all(6),
                child: Icon(Icons.open_in_full, color: Colors.white, size: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _ScenarioViewport extends StatelessWidget {
  const _ScenarioViewport({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(child: child);
  }
}

final class _Scenario {
  const _Scenario({required this.title, required this.child});

  final String title;
  final Widget child;
}

PixaRequest _requestForPost(
  ImagePost post, {
  int? targetPixels,
  int? targetWidth,
  int? targetHeight,
  List<String> processors = const <String>[],
}) {
  assert(
    targetPixels == null || targetWidth == null && targetHeight == null,
    'Use either targetPixels or explicit targetWidth/targetHeight.',
  );
  return PixaRequest(
    source: PixaSource.network(Uri.parse(post.imageUrl)),
    targetSize:
        targetPixels == null && targetWidth == null && targetHeight == null
        ? null
        : PixaTargetSize(
            width: targetPixels ?? targetWidth,
            height: targetPixels ?? targetHeight,
          ),
    fit: BoxFit.cover,
    processors: processors,
    cachePolicy: const PixaCachePolicy.public(maxAge: Duration(days: 7)),
    priority: PixaPriority.normal,
    retryPolicy: const PixaRetryPolicy.exponential(maxAttempts: 2),
  );
}

PixaRequest _thumbnailRequestForPost(ImagePost post) {
  final int? width = post.thumbnailWidth;
  final int? height = post.thumbnailHeight;
  return PixaRequest(
    source: PixaSource.network(Uri.parse(post.lowResUrl())),
    targetSize: width == null && height == null
        ? const PixaTargetSize(width: 96, height: 96)
        : PixaTargetSize(width: width, height: height),
    fit: BoxFit.cover,
    cachePolicy: const PixaCachePolicy.public(maxAge: Duration(days: 7)),
    priority: PixaPriority.low,
    retryPolicy: const PixaRetryPolicy.exponential(maxAttempts: 2),
  );
}

Widget _progressBuilder(BuildContext context, PixaProgress? progress) {
  final int? received = progress?.receivedBytes;
  final int? expected = progress?.expectedBytes;
  final double? value = received != null && expected != null && expected > 0
      ? (received / expected).clamp(0.0, 1.0).toDouble()
      : null;
  return ColoredBox(
    color: const Color(0xFFE8ECEF),
    child: Center(
      child: SizedBox.square(
        dimension: 26,
        child: CircularProgressIndicator(strokeWidth: 2.4, value: value),
      ),
    ),
  );
}

Widget _errorBuilder(
  BuildContext context,
  PixaFailure failure,
  VoidCallback retry,
) {
  final ColorScheme colors = Theme.of(context).colorScheme;
  return ColoredBox(
    color: colors.errorContainer,
    child: Center(
      child: IconButton.filledTonal(
        tooltip: 'Retry',
        icon: const Icon(Icons.refresh),
        onPressed: retry,
      ),
    ),
  );
}

Widget _largeImageTileErrorBuilder(
  BuildContext context,
  PixaFailure failure,
  VoidCallback retry,
) {
  return const SizedBox.expand();
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  }
  return '$bytes B';
}
