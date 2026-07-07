import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flexbox_layout/flexbox_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';

import 'config/image_config.dart';
import 'models/image_post.dart';
import 'sources/image_source_factory.dart';

enum _GalleryLayout { flexRows, masonry, denseGrid }

/// Top-level example destinations.
enum PixaGalleryTab { gallery, scenarios, diagnostics }

const List<ImagePost> _learningPosts = <ImagePost>[
  ImagePost(
    id: 1001,
    imageUrl: 'https://www.gstatic.com/webp/gallery/1.jpg',
    width: 550,
    height: 368,
    source: SourceType.nekosia,
    thumbnailUrl: 'https://www.gstatic.com/webp/gallery/1.webp',
    thumbnailWidth: 550,
    thumbnailHeight: 368,
  ),
  ImagePost(
    id: 1002,
    imageUrl:
        'https://flutter.github.io/assets-for-api-docs/assets/widgets/owl.jpg',
    width: 512,
    height: 512,
    source: SourceType.nekosia,
  ),
  ImagePost(
    id: 1003,
    imageUrl:
        'https://flutter.github.io/assets-for-api-docs/assets/widgets/owl-2.jpg',
    width: 520,
    height: 521,
    source: SourceType.nekosia,
  ),
];

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
    this.initialTab = PixaGalleryTab.gallery,
  });

  /// Optional posts injected by automated smoke tests.
  final List<ImagePost> initialPosts;

  /// Whether the gallery should fetch the configured public source on start.
  final bool loadOnStart;

  /// Initial example destination.
  final PixaGalleryTab initialTab;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pixa Gallery',
      debugShowCheckedModeBanner: false,
      theme: _pixaGalleryTheme(),
      home: PixaGalleryHome(
        initialPosts: initialPosts,
        loadOnStart: loadOnStart,
        initialTab: initialTab,
      ),
    );
  }
}

ThemeData _pixaGalleryTheme() {
  final ColorScheme colors = ColorScheme.fromSeed(
    seedColor: const Color(0xFF126B5B),
    dynamicSchemeVariant: DynamicSchemeVariant.expressive,
  );
  final TextTheme textTheme = ThemeData(useMaterial3: true).textTheme.apply(
    bodyColor: colors.onSurface,
    displayColor: colors.onSurface,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: colors.surface,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 2,
      backgroundColor: colors.surfaceContainer,
      foregroundColor: colors.onSurface,
      surfaceTintColor: colors.surfaceTint,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: colors.onSurface,
        fontWeight: FontWeight.w800,
        letterSpacing: 0,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 76,
      backgroundColor: colors.surfaceContainer,
      indicatorColor: colors.tertiaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith<IconThemeData>((
        Set<WidgetState> states,
      ) {
        return IconThemeData(
          color: states.contains(WidgetState.selected)
              ? colors.onTertiaryContainer
              : colors.onSurfaceVariant,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>((
        Set<WidgetState> states,
      ) {
        return textTheme.labelMedium?.copyWith(
          color: states.contains(WidgetState.selected)
              ? colors.onSurface
              : colors.onSurfaceVariant,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w800
              : FontWeight.w600,
          letterSpacing: 0,
        );
      }),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        side: WidgetStateProperty.resolveWith<BorderSide>((
          Set<WidgetState> states,
        ) {
          return BorderSide(
            color: states.contains(WidgetState.selected)
                ? colors.primary
                : colors.outlineVariant,
          );
        }),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      selectedColor: colors.secondaryContainer,
      backgroundColor: colors.surfaceContainerHighest,
      labelStyle: textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: colors.surfaceContainer,
      surfaceTintColor: colors.surfaceTint,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  );
}

/// Network gallery adapted from the flexbox example for Pixa.
final class PixaGalleryHome extends StatefulWidget {
  /// Creates the gallery home.
  const PixaGalleryHome({
    super.key,
    this.initialPosts = const <ImagePost>[],
    this.loadOnStart = true,
    this.initialTab = PixaGalleryTab.gallery,
  });

  /// Optional posts injected by automated smoke tests.
  final List<ImagePost> initialPosts;

  /// Whether the gallery should fetch the configured public source on start.
  final bool loadOnStart;

  /// Initial example destination.
  final PixaGalleryTab initialTab;

  @override
  State<PixaGalleryHome> createState() => _PixaGalleryHomeState();
}

final class _PixaGalleryHomeState extends State<PixaGalleryHome> {
  final ScrollController _scrollController = ScrollController();
  final List<ImagePost> _posts = <ImagePost>[];
  List<double> _aspectRatios = const <double>[];
  late final PixaPredictivePrefetcher _prefetcher;

  SourceType _selectedSource = ImageConfig.currentSource;
  late PixaGalleryTab _selectedTab;
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
    _selectedTab = widget.initialTab;
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
  void didUpdateWidget(PixaGalleryHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _selectedTab = widget.initialTab;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool useNavigationRail = MediaQuery.sizeOf(context).width >= 900;
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
      body: useNavigationRail
          ? Row(
              children: <Widget>[
                _buildNavigationRail(),
                VerticalDivider(
                  width: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                Expanded(child: _buildSelectedPage()),
              ],
            )
          : _buildSelectedPage(),
      bottomNavigationBar: useNavigationRail ? null : _buildNavigationBar(),
    );
  }

  Widget _buildSelectedPage() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (Widget child, Animation<double> animation) {
        final Animation<Offset> offset = Tween<Offset>(
          begin: const Offset(0, 0.015),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offset, child: child),
        );
      },
      child: KeyedSubtree(
        key: ValueKey<PixaGalleryTab>(_selectedTab),
        child: switch (_selectedTab) {
          PixaGalleryTab.gallery => _buildGalleryBody(),
          PixaGalleryTab.scenarios => _ScenarioSection(posts: _posts),
          PixaGalleryTab.diagnostics => _DiagnosticsPage(
            onPrefetchVisible: _prefetchVisible,
            onTrimMemory: _trimMemory,
            onShowCacheStats: _showCacheStats,
          ),
        },
      ),
    );
  }

  Widget _buildNavigationRail() {
    return NavigationRail(
      selectedIndex: _selectedTab.index,
      onDestinationSelected: _selectTab,
      labelType: NavigationRailLabelType.all,
      minWidth: 86,
      groupAlignment: -0.88,
      destinations: const <NavigationRailDestination>[
        NavigationRailDestination(
          icon: Icon(Icons.photo_library_outlined),
          selectedIcon: Icon(Icons.photo_library),
          label: Text('Gallery'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.widgets_outlined),
          selectedIcon: Icon(Icons.widgets),
          label: Text('Scenarios'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.monitor_heart_outlined),
          selectedIcon: Icon(Icons.monitor_heart),
          label: Text('Diagnostics'),
        ),
      ],
    );
  }

  Widget _buildNavigationBar() {
    return NavigationBar(
      selectedIndex: _selectedTab.index,
      onDestinationSelected: _selectTab,
      destinations: const <NavigationDestination>[
        NavigationDestination(
          key: ValueKey<String>('tab-gallery'),
          icon: Icon(Icons.photo_library_outlined),
          selectedIcon: Icon(Icons.photo_library),
          label: 'Gallery',
        ),
        NavigationDestination(
          key: ValueKey<String>('tab-scenarios'),
          icon: Icon(Icons.widgets_outlined),
          selectedIcon: Icon(Icons.widgets),
          label: 'Scenarios',
        ),
        NavigationDestination(
          key: ValueKey<String>('tab-diagnostics'),
          icon: Icon(Icons.monitor_heart_outlined),
          selectedIcon: Icon(Icons.monitor_heart),
          label: 'Diagnostics',
        ),
      ],
    );
  }

  void _selectTab(int index) {
    setState(() {
      _selectedTab = PixaGalleryTab.values[index];
    });
  }

  Widget _buildGalleryBody() {
    return RefreshIndicator(
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
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.tertiaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.photo_library,
                          color: colors.onTertiaryContainer,
                          size: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Network image gallery',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: colors.onSurfaceVariant,
                                  letterSpacing: 0,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
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
                    const Icon(Icons.height, size: 18),
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
  late final TransformationController _overviewController =
      TransformationController();

  @override
  void dispose() {
    _controller.dispose();
    _overviewController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ImagePost post = widget.post;
    final bool useTiledViewer = _shouldUseTiledLargeViewer(post);
    final bool useOverviewOnly = _needsOverviewOnlyLargeViewer(post);
    return Scaffold(
      backgroundColor: const Color(0xFF111318),
      appBar: AppBar(
        title: Text('${post.source.name} #${post.id}'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Fit',
            icon: const Icon(Icons.fit_screen),
            onPressed: useOverviewOnly ? _resetOverview : _controller.reset,
          ),
          IconButton(
            tooltip: '100%',
            icon: const Icon(Icons.center_focus_strong),
            onPressed: useOverviewOnly
                ? () => _zoomOverview(1)
                : () => _controller.zoomTo(1),
          ),
          IconButton(
            tooltip: '200%',
            icon: const Icon(Icons.zoom_in),
            onPressed: useOverviewOnly
                ? () => _zoomOverview(2)
                : () => _controller.zoomTo(2),
          ),
        ],
      ),
      body: useOverviewOnly
          ? _OverviewLargeImageViewer(
              post: post,
              controller: _overviewController,
            )
          : PixaLargeImage(
              request: _requestForPost(
                post,
              ).copyWith(lowRes: _thumbnailRequestForPost(post)),
              imageWidth: post.width,
              imageHeight: post.height,
              controller: _controller,
              tileMode: useTiledViewer
                  ? PixaLargeImageTileMode.always
                  : PixaLargeImageTileMode.adaptive,
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

  void _resetOverview() {
    _overviewController.value = Matrix4.identity();
  }

  void _zoomOverview(double scale) {
    _overviewController.value = Matrix4.identity()
      ..scaleByDouble(scale, scale, 1, 1);
  }
}

final class _OverviewLargeImageViewer extends StatelessWidget {
  const _OverviewLargeImageViewer({
    required this.post,
    required this.controller,
  });

  final ImagePost post;
  final TransformationController controller;

  @override
  Widget build(BuildContext context) {
    final int maxEdge = math.max(post.width, post.height);
    final int targetMaxEdge = math.min(maxEdge, 2200);
    final double scale = targetMaxEdge / maxEdge;
    final PixaRequest overviewRequest = _requestForPost(
      post,
      targetWidth: math.max(1, (post.width * scale).round()),
      targetHeight: math.max(1, (post.height * scale).round()),
    ).copyWith(lowRes: _thumbnailRequestForPost(post));
    return ColoredBox(
      color: const Color(0xFF111318),
      child: InteractiveViewer(
        transformationController: controller,
        minScale: 0.5,
        maxScale: 4,
        child: Center(
          child: AspectRatio(
            aspectRatio: post.aspectRatio,
            child: PixaImage(
              request: overviewRequest,
              fit: BoxFit.contain,
              placeholder: const PixaPlaceholder.color(Color(0xFF1D222B)),
              progressBuilder: _progressBuilder,
              errorBuilder: _errorBuilder,
              transitionDuration: Duration.zero,
            ),
          ),
        ),
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

final class _DiagnosticsPage extends StatefulWidget {
  const _DiagnosticsPage({
    required this.onPrefetchVisible,
    required this.onTrimMemory,
    required this.onShowCacheStats,
  });

  final Future<void> Function() onPrefetchVisible;
  final Future<void> Function() onTrimMemory;
  final VoidCallback onShowCacheStats;

  @override
  State<_DiagnosticsPage> createState() => _DiagnosticsPageState();
}

final class _DiagnosticsPageState extends State<_DiagnosticsPage> {
  String _status = 'Snapshot ready';

  @override
  Widget build(BuildContext context) {
    final PixaDebugSnapshot snapshot = PixaDebugInspector.snapshot();
    final PixaCacheStats? cache = snapshot.cacheStats;
    final PixaDecodedCacheStats decoded = snapshot.decodedCacheStats;
    final PixaSchedulerStats? scheduler = snapshot.schedulerStats;
    final List<PixaRuntimeImageFormatCapability> formats =
        snapshot.capabilities.imageFormats;
    final Iterable<String> runtimeFormats = formats
        .where(
          (PixaRuntimeImageFormatCapability format) =>
              format.runtimeDisplay || format.processorDecode,
        )
        .map((PixaRuntimeImageFormatCapability format) => format.format.name);
    return RefreshIndicator(
      onRefresh: () async => setState(() {
        _status = 'Snapshot refreshed';
      }),
      child: ListView(
        key: const ValueKey<String>('pixa-diagnostics-scroll'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: <Widget>[
          Text(
            'Diagnostics',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _status,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                onPressed: () => unawaited(
                  _run('Prefetched visible window', widget.onPrefetchVisible),
                ),
                icon: const Icon(Icons.download_for_offline),
                label: const Text('Prefetch window'),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    unawaited(_run('Trimmed caches', widget.onTrimMemory)),
                icon: const Icon(Icons.memory),
                label: const Text('Trim memory'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  widget.onShowCacheStats();
                  setState(() {
                    _status = 'Cache stats copied to gallery status';
                  });
                },
                icon: const Icon(Icons.query_stats),
                label: const Text('Cache stats'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _DiagnosticCard(
            title: 'Runtime',
            icon: Icons.developer_board,
            rows: <_DiagnosticRow>[
              _DiagnosticRow(
                'Platform',
                snapshot.capabilities.platformStatus.platform,
              ),
              _DiagnosticRow(
                'Runtime',
                snapshot.capabilities.platformStatus.runtimeAvailable
                    ? 'available'
                    : 'unavailable',
              ),
              _DiagnosticRow(
                'Self-check',
                snapshot.platformSelfCheck.passed ? 'passed' : 'failed',
              ),
              _DiagnosticRow(
                'HTTP transport',
                snapshot.capabilities.httpTransport ? 'enabled' : 'disabled',
              ),
              _DiagnosticRow(
                'Disk cache',
                snapshot.capabilities.diskCache ? 'enabled' : 'disabled',
              ),
              _DiagnosticRow(
                'Pixel processors',
                snapshot.capabilities.pixelProcessors ? 'enabled' : 'disabled',
              ),
            ],
          ),
          _DiagnosticCard(
            title: 'Cache',
            icon: Icons.storage,
            rows: <_DiagnosticRow>[
              _DiagnosticRow(
                'Encoded memory',
                cache == null
                    ? 'unconfigured'
                    : _formatBytes(cache.memoryBytes),
              ),
              _DiagnosticRow(
                'Memory entries',
                cache?.memoryEntries.toString() ?? '0',
              ),
              _DiagnosticRow(
                'Hit rate',
                cache == null
                    ? '0.0%'
                    : '${(cache.hitRate * 100).toStringAsFixed(1)}%',
              ),
              _DiagnosticRow(
                'Disk writes',
                cache?.diskWrites.toString() ?? '0',
              ),
              _DiagnosticRow(
                'Processed hit rate',
                cache == null
                    ? '0.0%'
                    : '${(cache.processedHitRate * 100).toStringAsFixed(1)}%',
              ),
              _DiagnosticRow(
                'Live buffers',
                cache?.liveOwnedBufferHandles.toString() ?? '0',
              ),
            ],
          ),
          _DiagnosticCard(
            title: 'Decoded ImageCache',
            icon: Icons.photo_library,
            rows: <_DiagnosticRow>[
              _DiagnosticRow(
                'Entries',
                '${decoded.currentSize}/${decoded.maximumSize}',
              ),
              _DiagnosticRow(
                'Bytes',
                '${_formatBytes(decoded.currentSizeBytes)} / ${_formatBytes(decoded.maximumSizeBytes)}',
              ),
              _DiagnosticRow('Live images', decoded.liveImageCount.toString()),
              _DiagnosticRow(
                'Utilization',
                '${(decoded.byteUtilization * 100).clamp(0, 999).toStringAsFixed(1)}%',
              ),
            ],
          ),
          _DiagnosticCard(
            title: 'Scheduler',
            icon: Icons.speed,
            rows: <_DiagnosticRow>[
              _DiagnosticRow(
                'Active runtime loads',
                scheduler?.activeRuntimeLoads.toString() ?? '0',
              ),
              _DiagnosticRow(
                'Queue depth',
                scheduler?.queueDepth.toString() ?? '0',
              ),
              _DiagnosticRow(
                'In-flight requests',
                scheduler?.inflightRequests.toString() ?? '0',
              ),
              _DiagnosticRow(
                'Listeners',
                scheduler?.listeners.toString() ?? '0',
              ),
              _DiagnosticRow(
                'Coalesced',
                scheduler?.totalCoalesced.toString() ?? '0',
              ),
              _DiagnosticRow(
                'Backpressure dropped',
                scheduler?.totalBackpressureDropped.toString() ?? '0',
              ),
            ],
          ),
          _DiagnosticCard(
            title: 'Formats and plugins',
            icon: Icons.extension,
            rows: <_DiagnosticRow>[
              _DiagnosticRow('Image formats', formats.length.toString()),
              _DiagnosticRow(
                'Runtime formats',
                runtimeFormats.take(14).join(', '),
              ),
              _DiagnosticRow(
                'Region decode formats',
                formats
                    .where(
                      (PixaRuntimeImageFormatCapability format) =>
                          format.regionDecode,
                    )
                    .map(
                      (PixaRuntimeImageFormatCapability format) =>
                          format.format.name,
                    )
                    .join(', '),
              ),
              _DiagnosticRow(
                'Video-frame backends',
                snapshot.registryArchitecture.videoFrameBackends.toString(),
              ),
              _DiagnosticRow(
                'Runtime modules',
                snapshot.registryArchitecture.runtimeModules.toString(),
              ),
              _DiagnosticRow(
                'Single host binary',
                snapshot.registryArchitecture.runtimeCanUseSingleHostBinary
                    ? 'yes'
                    : 'no',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _run(String success, Future<void> Function() action) async {
    setState(() {
      _status = 'Running';
    });
    try {
      await action();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = success;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Action failed: $error';
      });
    }
  }
}

final class _DiagnosticCard extends StatelessWidget {
  const _DiagnosticCard({
    required this.title,
    required this.icon,
    required this.rows,
  });

  final String title;
  final IconData icon;
  final List<_DiagnosticRow> rows;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(icon, size: 20, color: colors.primary),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              for (final _DiagnosticRow row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        width: 150,
                        child: Text(
                          row.label,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: colors.onSurfaceVariant,
                                letterSpacing: 0,
                              ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          row.value.isEmpty ? '-' : row.value,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(letterSpacing: 0),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _DiagnosticRow {
  const _DiagnosticRow(this.label, this.value);

  final String label;
  final String value;
}

final class _ScenarioSection extends StatelessWidget {
  const _ScenarioSection({required this.posts});

  final List<ImagePost> posts;

  @override
  Widget build(BuildContext context) {
    final List<ImagePost> scenarioPosts = posts.isEmpty
        ? _learningPosts
        : posts;
    final ImagePost first = scenarioPosts.first;
    final bool usingLearningPosts = posts.isEmpty;
    final PixaDebugSnapshot snapshot = PixaDebugInspector.snapshot();
    final bool hasVideoFrameBackend =
        snapshot.registryArchitecture.videoFrameBackends > 0 &&
        snapshot.registryArchitecture.videoFrameEncodedOutputBackends > 0;
    final List<_ScenarioGroup> groups = <_ScenarioGroup>[
      _ScenarioGroup(
        title: 'Display APIs',
        scenarios: <_Scenario>[
          _Scenario(
            title: 'PixaImage',
            subtitle: 'Widget surface with fit and progress',
            icon: Icons.photo_outlined,
            child: PixaImage(
              request: _requestForPost(first, targetPixels: 480),
              fit: BoxFit.cover,
              placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
              progressBuilder: _progressBuilder,
              errorBuilder: _errorBuilder,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          _Scenario(
            title: 'Provider',
            subtitle: 'ImageProvider compatibility',
            icon: Icons.image_outlined,
            child: _ProviderPreview(post: first),
          ),
          _Scenario(
            title: 'Controller',
            subtitle: 'Reload, cancel, pause, resume',
            icon: Icons.tune,
            child: _ControllerPreview(post: first),
          ),
          _Scenario(
            title: 'Pipeline load',
            subtitle: 'Low-level bytes with typed metadata',
            icon: Icons.account_tree,
            child: _PipelinePreview(post: first),
          ),
        ],
      ),
      _ScenarioGroup(
        title: 'Sources',
        scenarios: <_Scenario>[
          _Scenario(
            title: 'Source bundle',
            subtitle: 'Network, file, asset, memory, bytes, custom',
            icon: Icons.account_tree_outlined,
            child: _SourceBundlePreview(post: first),
          ),
        ],
      ),
      _ScenarioGroup(
        title: 'Cache and Prefetch',
        scenarios: <_Scenario>[
          _Scenario(
            title: 'Low-res chain',
            subtitle: 'Preview swaps to full request',
            icon: Icons.swap_horiz,
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
          _Scenario(
            title: 'Cache policy',
            subtitle: 'Mode switch, prefetch, evict',
            icon: Icons.offline_bolt_outlined,
            child: _CachePolicyPreview(post: first),
          ),
          _Scenario(
            title: 'Decoded prewarm',
            subtitle: 'Flutter ImageCache integration',
            icon: Icons.memory,
            child: _PrewarmPreview(post: first),
          ),
        ],
      ),
      _ScenarioGroup(
        title: 'Processing and Metadata',
        scenarios: <_Scenario>[
          _Scenario(
            title: 'Processor lab',
            subtitle: 'All public Rust helpers',
            icon: Icons.auto_fix_high,
            child: _ProcessorLabPreview(post: first),
          ),
          _Scenario(
            title: 'Thumbnail',
            subtitle: 'No-upscale runtime transform',
            icon: Icons.photo_size_select_small,
            child: PixaImage(
              request: _requestForPost(
                first,
                targetPixels: 320,
                processors: <String>[PixaProcessors.thumbnail(320, 240)],
              ),
              fit: BoxFit.contain,
              background: const ColoredBox(color: Color(0xFFE8ECEF)),
              placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
              progressBuilder: _progressBuilder,
              errorBuilder: _errorBuilder,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          _Scenario(
            title: 'Metadata',
            subtitle: 'Header probe without full decode',
            icon: Icons.info_outline,
            child: _MetadataPreview(post: first),
          ),
        ],
      ),
      _ScenarioGroup(
        title: 'Large, Animated, Video',
        scenarios: <_Scenario>[
          _Scenario(
            title: 'Large viewer',
            subtitle: 'Tiled pan and zoom',
            icon: Icons.open_in_full,
            child: _LargeImagePreview(post: first),
          ),
          _Scenario(
            title: 'Progressive JPEG',
            subtitle: 'Streaming preview event',
            icon: Icons.downloading,
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
            subtitle: 'Playback controller',
            icon: Icons.movie_filter_outlined,
            child: const _AnimatedPreview(
              url: 'https://media.giphy.com/media/3oEjI6SIIHBdRxXI40/giphy.gif',
            ),
          ),
          _Scenario(
            title: 'Animated WebP',
            subtitle: 'Engine-backed animation path',
            icon: Icons.motion_photos_on_outlined,
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
            title: 'Video frame',
            subtitle: hasVideoFrameBackend
                ? 'Runtime backend available'
                : 'No backend in this binary',
            icon: Icons.video_file_outlined,
            child: hasVideoFrameBackend
                ? PixaImage.videoFrame(
                    'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
                    timestamp: const Duration(seconds: 1),
                    fit: BoxFit.cover,
                    placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
                    errorBuilder: _errorBuilder,
                    borderRadius: BorderRadius.circular(8),
                  )
                : const _DisabledScenarioPreview(
                    icon: Icons.video_file_outlined,
                    label: 'video-frame backend unavailable',
                  ),
          ),
        ],
      ),
      _ScenarioGroup(
        title: 'Failure Handling',
        scenarios: <_Scenario>[
          _Scenario(
            title: 'Retry',
            subtitle: 'Failure surface and retry',
            icon: Icons.refresh,
            child: PixaImage.network(
              'https://images.example.invalid/missing.jpg',
              fit: BoxFit.cover,
              placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
              errorBuilder: _errorBuilder,
              retryPolicy: const PixaRetryPolicy.exponential(maxAttempts: 2),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ],
      ),
    ];
    final int scenarioCount = groups.fold<int>(
      0,
      (int total, _ScenarioGroup group) => total + group.scenarios.length,
    );
    return CustomScrollView(
      key: const ValueKey<String>('pixa-scenarios-scroll'),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Pixa scenarios',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  usingLearningPosts
                      ? '$scenarioCount scenarios using real public images'
                      : '$scenarioCount scenarios using ${first.source.name} #${first.id}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: const <Widget>[
                    _LearningChip(icon: Icons.image_outlined, label: 'Widget'),
                    _LearningChip(icon: Icons.key, label: 'Provider'),
                    _LearningChip(icon: Icons.storage, label: 'Cache'),
                    _LearningChip(icon: Icons.speed, label: 'Prefetch'),
                    _LearningChip(icon: Icons.auto_fix_high, label: 'Process'),
                    _LearningChip(icon: Icons.open_in_full, label: 'Large'),
                  ],
                ),
              ],
            ),
          ),
        ),
        for (final _ScenarioGroup group in groups) ...<Widget>[
          SliverToBoxAdapter(child: _ScenarioGroupHeader(title: group.title)),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 320,
                mainAxisExtent: 326,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
              delegate: SliverChildBuilderDelegate(
                (BuildContext context, int index) {
                  return _ScenarioTile(scenario: group.scenarios[index]);
                },
                childCount: group.scenarios.length,
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: true,
                addSemanticIndexes: false,
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 6)),
      ],
    );
  }
}

final class _ScenarioGroupHeader extends StatelessWidget {
  const _ScenarioGroupHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

final class _LearningChip extends StatelessWidget {
  const _LearningChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(icon, size: 16, color: colors.onSecondaryContainer),
      label: Text(label),
      backgroundColor: colors.secondaryContainer,
      side: BorderSide.none,
    );
  }
}

final class _ScenarioTile extends StatelessWidget {
  const _ScenarioTile({required this.scenario});

  final _Scenario scenario;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainer,
      surfaceTintColor: colors.surfaceTint,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 4 / 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: ColoredBox(
                  color: colors.surfaceContainerHighest,
                  child: SizedBox.expand(child: scenario.child),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Icon(
                      scenario.icon,
                      size: 16,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    scenario.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              scenario.subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ProviderPreview extends StatelessWidget {
  const _ProviderPreview({required this.post});

  final ImagePost post;

  @override
  Widget build(BuildContext context) {
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int? targetWidth = _targetDimension(constraints.maxWidth, dpr);
        final int? targetHeight = _targetDimension(constraints.maxHeight, dpr);
        return Image(
          image: PixaProvider.network(
            post.imageUrl,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            cachePolicy: const PixaCachePolicy.public(
              maxAge: Duration(days: 7),
            ),
            retryPolicy: const PixaRetryPolicy.exponential(maxAttempts: 2),
          ),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.none,
        );
      },
    );
  }
}

final class _ControllerPreview extends StatefulWidget {
  const _ControllerPreview({required this.post});

  final ImagePost post;

  @override
  State<_ControllerPreview> createState() => _ControllerPreviewState();
}

final class _ControllerPreviewState extends State<_ControllerPreview> {
  late final PixaController _controller = PixaController()
    ..addListener(_handleControllerChanged);
  String _status = 'ready';
  bool _statusUpdateScheduled = false;

  @override
  void dispose() {
    _controller
      ..removeListener(_handleControllerChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        PixaImage(
          controller: _controller,
          request: _requestForPost(widget.post, targetPixels: 360),
          fit: BoxFit.cover,
          placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
          progressBuilder: _progressBuilder,
          errorBuilder: _errorBuilder,
          borderRadius: BorderRadius.circular(8),
        ),
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.58),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    _status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Colors.white,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      _SmallIconButton(
                        tooltip: 'Reload',
                        icon: Icons.refresh,
                        onPressed: _controller.reload,
                      ),
                      _SmallIconButton(
                        tooltip: 'Cancel',
                        icon: Icons.close,
                        onPressed: _controller.cancel,
                      ),
                      _SmallIconButton(
                        tooltip: 'Pause',
                        icon: Icons.pause,
                        onPressed: _controller.pause,
                      ),
                      _SmallIconButton(
                        tooltip: 'Resume',
                        icon: Icons.play_arrow,
                        onPressed: _controller.resume,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _handleControllerChanged() {
    if (!mounted || _statusUpdateScheduled) {
      return;
    }
    _statusUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _statusUpdateScheduled = false;
      if (!mounted) {
        return;
      }
      final String visibility = _controller.isVisible ? 'visible' : 'paused';
      setState(() {
        _status =
            '${_controller.state.runtimeType} · '
            'gen ${_controller.generation} · $visibility';
      });
    });
  }
}

final class _PipelinePreview extends StatefulWidget {
  const _PipelinePreview({required this.post});

  final ImagePost post;

  @override
  State<_PipelinePreview> createState() => _PipelinePreviewState();
}

final class _PipelinePreviewState extends State<_PipelinePreview> {
  Uint8List? _bytes;
  String _status = 'loading pipeline';
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(_PipelinePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.imageUrl != widget.post.imageUrl) {
      setState(() {
        _bytes = null;
        _status = 'loading pipeline';
        _error = null;
      });
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = _bytes;
    if (_error != null) {
      return const _DisabledScenarioPreview(
        icon: Icons.error_outline,
        label: 'pipeline load failed',
      );
    }
    if (bytes == null) {
      return const _MiniLoadingPreview(label: 'loading pipeline');
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        PixaImage.bytes(
          bytes,
          id: 'pipeline-${widget.post.id}',
          fit: BoxFit.cover,
          placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
          errorBuilder: _errorBuilder,
          borderRadius: BorderRadius.circular(8),
        ),
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.58),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                _status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Colors.white,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _load() async {
    try {
      final PixaPipelineLoad load = await Pixa.pipeline.load(
        _requestForPost(
          widget.post,
          targetPixels: 360,
        ).copyWith(cachePolicy: const PixaCachePolicy.noStore()),
      );
      final Uint8List bytes;
      final String status;
      try {
        bytes = Uint8List.fromList(load.bytes);
        status =
            '${_formatBytes(bytes.length)} · ${load.mimeType ?? 'unknown'}';
      } finally {
        load.dispose();
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _bytes = bytes;
        _status = status;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
      });
    }
  }
}

final class _SourceBundlePreview extends StatefulWidget {
  const _SourceBundlePreview({required this.post});

  final ImagePost post;

  @override
  State<_SourceBundlePreview> createState() => _SourceBundlePreviewState();
}

final class _SourceBundlePreviewState extends State<_SourceBundlePreview> {
  Uint8List? _bytes;
  File? _file;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadEncodedBytes());
  }

  @override
  void didUpdateWidget(_SourceBundlePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.imageUrl != widget.post.imageUrl) {
      _deleteFile();
      setState(() {
        _bytes = null;
        _file = null;
        _error = null;
      });
      unawaited(_loadEncodedBytes());
    }
  }

  @override
  void dispose() {
    _deleteFile();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = _bytes;
    final File? file = _file;
    if (_error != null) {
      return _DisabledScenarioPreview(
        icon: Icons.error_outline,
        label: 'source bundle failed',
      );
    }
    if (bytes == null || file == null) {
      return const _MiniLoadingPreview(label: 'loading source bytes');
    }
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        children: <Widget>[
          Expanded(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _SourceMini(
                    label: 'network',
                    child: PixaImage(
                      request: _requestForPost(widget.post, targetPixels: 160),
                      fit: BoxFit.cover,
                      placeholder: const PixaPlaceholder.color(
                        Color(0xFFE8ECEF),
                      ),
                      errorBuilder: _errorBuilder,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _SourceMini(
                    label: 'file',
                    child: PixaImage.file(
                      file.path,
                      fit: BoxFit.cover,
                      exifThumbnailFirst: false,
                      placeholder: const PixaPlaceholder.color(
                        Color(0xFFE8ECEF),
                      ),
                      errorBuilder: _errorBuilder,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _SourceMini(
                    label: 'asset',
                    child: PixaImage.asset(
                      'assets/pixa_sample.ppm',
                      fit: BoxFit.cover,
                      placeholder: const PixaPlaceholder.color(
                        Color(0xFFE8ECEF),
                      ),
                      errorBuilder: _errorBuilder,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _SourceMini(
                    label: 'memory',
                    child: PixaImage.memory(
                      'source-memory-${widget.post.id}',
                      bytes,
                      fit: BoxFit.cover,
                      placeholder: const PixaPlaceholder.color(
                        Color(0xFFE8ECEF),
                      ),
                      errorBuilder: _errorBuilder,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _SourceMini(
                    label: 'bytes',
                    child: PixaImage.bytes(
                      bytes,
                      id: 'source-bytes-${widget.post.id}',
                      fit: BoxFit.cover,
                      placeholder: const PixaPlaceholder.color(
                        Color(0xFFE8ECEF),
                      ),
                      errorBuilder: _errorBuilder,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _SourceMini(
                    label: 'custom',
                    child: PixaImage(
                      request: PixaRequest(
                        source: PixaSource.custom(
                          'source-custom-${widget.post.id}',
                          () async => bytes,
                        ),
                        targetSize: const PixaTargetSize(
                          width: 160,
                          height: 160,
                        ),
                        fit: BoxFit.cover,
                        cachePolicy: const PixaCachePolicy.noStore(),
                      ),
                      fit: BoxFit.cover,
                      placeholder: const PixaPlaceholder.color(
                        Color(0xFFE8ECEF),
                      ),
                      errorBuilder: _errorBuilder,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadEncodedBytes() async {
    try {
      final PixaPipelineLoad load = await Pixa.pipeline.load(
        _requestForPost(
          widget.post,
          targetPixels: 320,
        ).copyWith(cachePolicy: const PixaCachePolicy.noStore()),
      );
      final Uint8List bytes;
      try {
        bytes = Uint8List.fromList(load.bytes);
      } finally {
        load.dispose();
      }
      final File file = File(
        '${Directory.systemTemp.path}/pixa-gallery-source-'
        '${widget.post.id}-${DateTime.now().microsecondsSinceEpoch}.img',
      );
      await file.writeAsBytes(bytes, flush: false);
      if (!mounted) {
        unawaited(file.delete());
        return;
      }
      setState(() {
        _bytes = bytes;
        _file = file;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
      });
    }
  }

  void _deleteFile() {
    final File? file = _file;
    _file = null;
    if (file != null && file.existsSync()) {
      try {
        file.deleteSync();
      } on FileSystemException {
        // Best-effort cleanup for native-only example temp files.
      }
    }
  }
}

final class _SourceMini extends StatelessWidget {
  const _SourceMini({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          child,
          Positioned(
            left: 4,
            right: 4,
            bottom: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.58),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _CachePolicyPreview extends StatefulWidget {
  const _CachePolicyPreview({required this.post});

  final ImagePost post;

  @override
  State<_CachePolicyPreview> createState() => _CachePolicyPreviewState();
}

final class _CachePolicyPreviewState extends State<_CachePolicyPreview> {
  PixaCacheMode _mode = PixaCacheMode.memoryAndDisk;
  String _status = 'memory + disk';

  @override
  Widget build(BuildContext context) {
    final PixaRequest request = _requestForPost(
      widget.post,
      targetPixels: 360,
    ).copyWith(cachePolicy: PixaCachePolicy(mode: _mode));
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        PixaImage(
          request: request,
          fit: BoxFit.cover,
          placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
          progressBuilder: _progressBuilder,
          errorBuilder: _errorBuilder,
          borderRadius: BorderRadius.circular(8),
        ),
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.58),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          _status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: Colors.white, letterSpacing: 0),
                        ),
                      ),
                      PopupMenuButton<PixaCacheMode>(
                        tooltip: 'Cache mode',
                        icon: const Icon(
                          Icons.storage,
                          color: Colors.white,
                          size: 18,
                        ),
                        onSelected: _selectMode,
                        itemBuilder: (BuildContext context) =>
                            <PopupMenuEntry<PixaCacheMode>>[
                              for (final PixaCacheMode mode
                                  in PixaCacheMode.values)
                                PopupMenuItem<PixaCacheMode>(
                                  value: mode,
                                  child: Text(_cacheModeLabel(mode)),
                                ),
                            ],
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      _SmallIconButton(
                        tooltip: 'Prefetch encoded memory',
                        icon: Icons.download_for_offline,
                        onPressed: () => unawaited(_prefetch(request)),
                      ),
                      _SmallIconButton(
                        tooltip: 'Evict encoded and decoded',
                        icon: Icons.delete_sweep,
                        onPressed: () => unawaited(_evict(request)),
                      ),
                      _SmallIconButton(
                        tooltip: 'Show cache stats',
                        icon: Icons.query_stats,
                        onPressed: _showStats,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _selectMode(PixaCacheMode mode) {
    setState(() {
      _mode = mode;
      _status = _cacheModeLabel(mode);
    });
  }

  Future<void> _prefetch(PixaRequest request) async {
    try {
      await Pixa.prefetch(request, target: PixaPrefetchTarget.encodedMemory);
      if (mounted) {
        setState(() {
          _status = 'encoded prefetch complete';
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _status = 'prefetch failed';
        });
      }
      debugPrint('Pixa cache scenario prefetch failed: $error');
    }
  }

  Future<void> _evict(PixaRequest request) async {
    await Pixa.evict(request);
    if (mounted) {
      setState(() {
        _status = 'evicted request caches';
      });
    }
  }

  void _showStats() {
    final PixaCacheStats stats = Pixa.cacheStats();
    setState(() {
      _status =
          '${_formatBytes(stats.memoryBytes)} · '
          '${(stats.hitRate * 100).toStringAsFixed(1)}% hit';
    });
  }
}

final class _ProcessorLabPreview extends StatefulWidget {
  const _ProcessorLabPreview({required this.post});

  final ImagePost post;

  @override
  State<_ProcessorLabPreview> createState() => _ProcessorLabPreviewState();
}

final class _ProcessorLabPreviewState extends State<_ProcessorLabPreview> {
  late final List<_ProcessorDemo> _demos = _processorDemos();
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final _ProcessorDemo demo = _demos[_index];
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        PixaImage(
          request: _requestForPost(
            widget.post,
            targetPixels: 360,
            processors: demo.processors,
          ),
          fit: BoxFit.cover,
          placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
          progressBuilder: _progressBuilder,
          errorBuilder: _errorBuilder,
          borderRadius: BorderRadius.circular(8),
        ),
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.58),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      demo.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Colors.white,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  PopupMenuButton<int>(
                    tooltip: 'Processor',
                    icon: const Icon(
                      Icons.auto_fix_high,
                      color: Colors.white,
                      size: 18,
                    ),
                    onSelected: (int value) => setState(() {
                      _index = value;
                    }),
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<int>>[
                          for (var i = 0; i < _demos.length; i += 1)
                            PopupMenuItem<int>(
                              value: i,
                              child: Text(_demos[i].label),
                            ),
                        ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final class _MetadataPreview extends StatefulWidget {
  const _MetadataPreview({required this.post});

  final ImagePost post;

  @override
  State<_MetadataPreview> createState() => _MetadataPreviewState();
}

final class _MetadataPreviewState extends State<_MetadataPreview> {
  PixaImageMetadata? _metadata;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  @override
  void didUpdateWidget(_MetadataPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post.imageUrl != widget.post.imageUrl) {
      setState(() {
        _metadata = null;
        _error = null;
      });
      unawaited(_probe());
    }
  }

  @override
  Widget build(BuildContext context) {
    final PixaImageMetadata? metadata = _metadata;
    if (_error != null) {
      return const _DisabledScenarioPreview(
        icon: Icons.error_outline,
        label: 'metadata probe failed',
      );
    }
    if (metadata == null) {
      return const _MiniLoadingPreview(label: 'probing metadata');
    }
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _MetadataLine(label: 'format', value: metadata.format.name),
            _MetadataLine(
              label: 'size',
              value: '${metadata.width} x ${metadata.height}',
            ),
            _MetadataLine(
              label: 'animated',
              value: metadata.isAnimated ? 'yes' : 'no',
            ),
            _MetadataLine(
              label: 'progressive',
              value: metadata.isProgressive ? 'yes' : 'no',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _probe() async {
    try {
      final PixaPipelineLoad load = await Pixa.pipeline.load(
        _requestForPost(
          widget.post,
          targetPixels: 320,
        ).copyWith(cachePolicy: const PixaCachePolicy.noStore()),
      );
      final PixaImageMetadata metadata;
      try {
        metadata = PixaImageMetadata.parseEncoded(load.bytes);
      } finally {
        load.dispose();
      }
      if (mounted) {
        setState(() {
          _metadata = metadata;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
        });
      }
    }
  }
}

final class _PrewarmPreview extends StatefulWidget {
  const _PrewarmPreview({required this.post});

  final ImagePost post;

  @override
  State<_PrewarmPreview> createState() => _PrewarmPreviewState();
}

final class _PrewarmPreviewState extends State<_PrewarmPreview> {
  String _status = 'Tap to prewarm decoded cache';
  bool _isRunning = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        PixaImage(
          request: _requestForPost(widget.post, targetPixels: 360),
          fit: BoxFit.cover,
          placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
          errorBuilder: _errorBuilder,
          borderRadius: BorderRadius.circular(8),
        ),
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: FilledButton.tonalIcon(
            onPressed: _isRunning ? null : _prewarm,
            icon: _isRunning
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.memory, size: 18),
            label: Text(_status, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
    );
  }

  Future<void> _prewarm() async {
    setState(() {
      _isRunning = true;
      _status = 'Prewarming';
    });
    try {
      await Pixa.prefetch(
        _requestForPost(widget.post, targetPixels: 360),
        target: PixaPrefetchTarget.decodedPrewarm,
        context: context,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Decoded cache warm';
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Prewarm failed';
      });
      debugPrint('Pixa prewarm scenario failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isRunning = false;
        });
      }
    }
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

final class _AnimatedPreview extends StatefulWidget {
  const _AnimatedPreview({required this.url});

  final String url;

  @override
  State<_AnimatedPreview> createState() => _AnimatedPreviewState();
}

final class _AnimatedPreviewState extends State<_AnimatedPreview> {
  late final PixaAnimationController _controller = PixaAnimationController()
    ..addListener(_handleChanged);
  String _status = 'playing';

  @override
  void dispose() {
    _controller
      ..removeListener(_handleChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        PixaImage.network(
          widget.url,
          fit: BoxFit.cover,
          animationController: _controller,
          placeholder: const PixaPlaceholder.color(Color(0xFFE8ECEF)),
          progressBuilder: _progressBuilder,
          errorBuilder: _errorBuilder,
          borderRadius: BorderRadius.circular(8),
        ),
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.58),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Colors.white,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                  _SmallIconButton(
                    tooltip: 'Play',
                    icon: Icons.play_arrow,
                    onPressed: _controller.play,
                  ),
                  _SmallIconButton(
                    tooltip: 'Pause',
                    icon: Icons.pause,
                    onPressed: _controller.pause,
                  ),
                  _SmallIconButton(
                    tooltip: 'Stop',
                    icon: Icons.stop,
                    onPressed: _controller.stop,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _handleChanged() {
    if (!mounted) {
      return;
    }
    setState(() {
      _status = _controller.state.name;
    });
  }
}

final class _SmallIconButton extends StatelessWidget {
  const _SmallIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
      color: Colors.white,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
    );
  }
}

final class _MiniLoadingPreview extends StatelessWidget {
  const _MiniLoadingPreview({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _MetadataLine extends StatelessWidget {
  const _MetadataLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
                letterSpacing: 0,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _DisabledScenarioPreview extends StatelessWidget {
  const _DisabledScenarioPreview({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 32, color: colors.onSurfaceVariant),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _Scenario {
  const _Scenario({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;
}

final class _ScenarioGroup {
  const _ScenarioGroup({required this.title, required this.scenarios});

  final String title;
  final List<_Scenario> scenarios;
}

final class _ProcessorDemo {
  const _ProcessorDemo({required this.label, required this.processors});

  final String label;
  final List<String> processors;
}

List<_ProcessorDemo> _processorDemos() {
  return <_ProcessorDemo>[
    _ProcessorDemo(
      label: 'resize fit',
      processors: <String>[PixaProcessors.resize(width: 320)],
    ),
    _ProcessorDemo(
      label: 'resize exact',
      processors: <String>[PixaProcessors.resizeExact(240, 160)],
    ),
    _ProcessorDemo(
      label: 'resize to fill',
      processors: <String>[PixaProcessors.resizeToFill(320, 240)],
    ),
    _ProcessorDemo(
      label: 'thumbnail',
      processors: <String>[PixaProcessors.thumbnail(320, 240)],
    ),
    _ProcessorDemo(
      label: 'thumbnail exact',
      processors: <String>[PixaProcessors.thumbnailExact(160, 160)],
    ),
    _ProcessorDemo(
      label: 'crop',
      processors: <String>[
        PixaProcessors.crop(x: 0, y: 0, width: 1, height: 1),
      ],
    ),
    _ProcessorDemo(
      label: 'tile crop resize',
      processors: <String>[
        PixaProcessors.tileCropResize(
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          decodedWidth: 160,
          decodedHeight: 160,
        ),
      ],
    ),
    _ProcessorDemo(
      label: 'rotate',
      processors: <String>[PixaProcessors.rotate(90)],
    ),
    _ProcessorDemo(
      label: 'blur',
      processors: <String>[PixaProcessors.blur(2.0)],
    ),
    _ProcessorDemo(
      label: 'fast blur',
      processors: <String>[PixaProcessors.fastBlur(2.0)],
    ),
    _ProcessorDemo(
      label: 'filter 3x3',
      processors: <String>[
        PixaProcessors.filter3x3(const <double>[0, -1, 0, -1, 5, -1, 0, -1, 0]),
      ],
    ),
    _ProcessorDemo(
      label: 'flip horizontal',
      processors: <String>[PixaProcessors.flipHorizontal()],
    ),
    _ProcessorDemo(
      label: 'flip vertical',
      processors: <String>[PixaProcessors.flipVertical()],
    ),
    _ProcessorDemo(
      label: 'grayscale',
      processors: <String>[PixaProcessors.grayscale()],
    ),
    _ProcessorDemo(
      label: 'invert',
      processors: <String>[PixaProcessors.invert()],
    ),
    _ProcessorDemo(
      label: 'brighten',
      processors: <String>[PixaProcessors.brighten(24)],
    ),
    _ProcessorDemo(
      label: 'contrast',
      processors: <String>[PixaProcessors.contrast(28)],
    ),
    _ProcessorDemo(
      label: 'hue rotate',
      processors: <String>[PixaProcessors.hueRotate(45)],
    ),
    _ProcessorDemo(
      label: 'unsharpen',
      processors: <String>[PixaProcessors.unsharpen(sigma: 1.0, threshold: 2)],
    ),
    const _ProcessorDemo(
      label: 'watermark',
      processors: <String>[
        'watermark(text=Pixa,position=bottomRight,padding=14,scale=2)',
      ],
    ),
  ];
}

String _cacheModeLabel(PixaCacheMode mode) {
  return switch (mode) {
    PixaCacheMode.noStore => 'no store',
    PixaCacheMode.memoryOnly => 'memory only',
    PixaCacheMode.diskOnly => 'disk only',
    PixaCacheMode.memoryAndDisk => 'memory + disk',
    PixaCacheMode.cacheOnly => 'cache only',
    PixaCacheMode.networkOnly => 'network only',
    PixaCacheMode.refresh => 'refresh',
    PixaCacheMode.staleWhileRevalidate => 'stale while revalidate',
  };
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

bool _shouldUseTiledLargeViewer(ImagePost post) {
  return post.width * post.height >= 12 * 1024 * 1024 &&
      _hasRegionDecodeForPost(post);
}

bool _needsOverviewOnlyLargeViewer(ImagePost post) {
  return post.width * post.height >= 12 * 1024 * 1024 &&
      !_hasRegionDecodeForPost(post);
}

bool _hasRegionDecodeForPost(ImagePost post) {
  final PixaImageMetadataFormat? format = _formatFromImageUrl(post.imageUrl);
  if (format == null) {
    return false;
  }
  return PixaDebugInspector.snapshot().capabilities.imageFormats.any(
    (PixaRuntimeImageFormatCapability capability) =>
        capability.format == format && capability.regionDecode,
  );
}

PixaImageMetadataFormat? _formatFromImageUrl(String imageUrl) {
  final String path = Uri.tryParse(imageUrl)?.path.toLowerCase() ?? '';
  if (path.endsWith('.jpg') || path.endsWith('.jpeg')) {
    return PixaImageMetadataFormat.jpeg;
  }
  if (path.endsWith('.png')) {
    return PixaImageMetadataFormat.png;
  }
  if (path.endsWith('.gif')) {
    return PixaImageMetadataFormat.gif;
  }
  if (path.endsWith('.webp')) {
    return PixaImageMetadataFormat.webp;
  }
  if (path.endsWith('.bmp')) {
    return PixaImageMetadataFormat.bmp;
  }
  if (path.endsWith('.wbmp')) {
    return PixaImageMetadataFormat.wbmp;
  }
  if (path.endsWith('.ico')) {
    return PixaImageMetadataFormat.ico;
  }
  if (path.endsWith('.tif') || path.endsWith('.tiff')) {
    return PixaImageMetadataFormat.tiff;
  }
  if (path.endsWith('.pnm') ||
      path.endsWith('.pbm') ||
      path.endsWith('.pgm') ||
      path.endsWith('.ppm') ||
      path.endsWith('.pam')) {
    return PixaImageMetadataFormat.pnm;
  }
  if (path.endsWith('.qoi')) {
    return PixaImageMetadataFormat.qoi;
  }
  if (path.endsWith('.tga')) {
    return PixaImageMetadataFormat.tga;
  }
  if (path.endsWith('.dds')) {
    return PixaImageMetadataFormat.dds;
  }
  if (path.endsWith('.hdr')) {
    return PixaImageMetadataFormat.hdr;
  }
  if (path.endsWith('.ff')) {
    return PixaImageMetadataFormat.farbfeld;
  }
  if (path.endsWith('.pcx')) {
    return PixaImageMetadataFormat.pcx;
  }
  if (path.endsWith('.sgi') ||
      path.endsWith('.rgb') ||
      path.endsWith('.rgba') ||
      path.endsWith('.bw')) {
    return PixaImageMetadataFormat.sgi;
  }
  if (path.endsWith('.xbm')) {
    return PixaImageMetadataFormat.xbm;
  }
  if (path.endsWith('.xpm')) {
    return PixaImageMetadataFormat.xpm;
  }
  return null;
}

int? _targetDimension(double logicalExtent, double devicePixelRatio) {
  if (!logicalExtent.isFinite || logicalExtent <= 0) {
    return null;
  }
  return (logicalExtent * devicePixelRatio).ceil().clamp(1, 1 << 30).toInt();
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
