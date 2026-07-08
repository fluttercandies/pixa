import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';

import '../config/image_config.dart';
import '../models/image_post.dart';
import '../sources/image_source.dart';
import '../theme/neu_palette.dart';
import '../widgets/neu_controls.dart';
import '../widgets/neu_refresh.dart';
import '../widgets/neu_surface.dart';
import '../sources/image_source_factory.dart';
import 'gallery_slivers.dart';
import 'gallery_states.dart';
import 'gallery_workbench.dart';
import 'large_image_page.dart';

/// The live network gallery page.
///
/// Owns: posts list, source selection, layout, paging, predictive
/// prefetch and refresh. Renders a neumorphic workbench header followed
/// by a flex / masonry / grid feed.
class GalleryPage extends StatefulWidget {
  const GalleryPage({
    super.key,
    this.initialPosts = const <ImagePost>[],
    this.loadOnStart = true,
    this.initialSource,
    this.onPostsChanged,
  });

  final List<ImagePost> initialPosts;
  final bool loadOnStart;
  final SourceType? initialSource;
  final ValueChanged<List<ImagePost>>? onPostsChanged;

  @override
  State<GalleryPage> createState() => GalleryPageState();
}

@visibleForTesting
class GalleryPageState extends State<GalleryPage> {
  final ScrollController _scrollController = ScrollController();
  late final PixaPredictivePrefetcher _prefetcher;

  List<ImagePost> _posts = <ImagePost>[];
  SourceType _source = SourceType.nekosia;
  GalleryLayout _layout = GalleryLayout.flexRows;
  double _targetRowHeight = 180;
  String _searchQuery = '';
  GallerySizeFilter _sizeFilter = GallerySizeFilter.all;

  // Favorites (in-memory for session persistence).
  final Set<int> _favoriteIds = <int>{};
  bool _favoritesOnly = false;

  void _toggleFavorite(int id) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_favoriteIds.contains(id)) {
        _favoriteIds.remove(id);
      } else {
        _favoriteIds.add(id);
      }
    });
  }

  // Multi-select state.
  bool _multiSelectMode = false;
  final Set<int> _selectedIds = <int>{};

  bool _isLoading = false;
  bool _hasMore = true;
  int _currentPage = 1;
  String? _error;
  bool _offlineMode = false;

  @override
  void initState() {
    super.initState();
    _posts = List<ImagePost>.of(widget.initialPosts);
    _source = widget.initialSource ?? ImageConfig.currentSource;
    _prefetcher = PixaPredictivePrefetcher(
      requestBuilder: (int index) =>
          prefetchRequestForIndex(_posts, index, _layout, _targetRowHeight),
      target: PixaPrefetchTarget.diskOnly,
      forwardItemCount: 20,
      backwardItemCount: 4,
      maxConcurrent: 2,
    );
    _scrollController.addListener(_onScroll);
    if (widget.loadOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadFirst());
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _prefetcher.clearHistory();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _posts.isEmpty) {
      return;
    }
    final ScrollPosition pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 600 && !_isLoading && _hasMore) {
      _loadMore();
    }
    // Approximate the visible index window from the scroll offset and the
    // viewport height. This is only used to drive the predictive prefetcher;
    // the tiles themselves stay layout-driven and never read this value.
    final double viewport = pos.viewportDimension;
    final int perScreen = (viewport / 220).ceil().clamp(1, _posts.length);
    final int first = (pos.pixels / 220).floor().clamp(0, _posts.length - 1);
    final int last = (first + perScreen).clamp(first, _posts.length - 1);
    _prefetcher.prefetchAround(
      firstVisibleIndex: first,
      lastVisibleIndex: last,
      itemCount: _posts.length,
    );
  }

  /// Returns the subset of [_posts] matching the current search query and
  /// size filter. This is computed on every build (cheap for hundreds of
  /// posts) so the feed reacts instantly as the user types.
  List<ImagePost> get _filteredPosts {
    if (_searchQuery.isEmpty &&
        _sizeFilter == GallerySizeFilter.all &&
        !_favoritesOnly) {
      return _posts;
    }
    final q = _searchQuery.toLowerCase();
    return _posts.where((p) {
      final matchesQuery =
          q.isEmpty ||
          p.id.toString().contains(q) ||
          p.source.name.toLowerCase().contains(q) ||
          '${p.width}×${p.height}'.contains(q) ||
          p.imageUrl.toLowerCase().contains(q);
      final matchesSize = switch (_sizeFilter) {
        GallerySizeFilter.all => true,
        GallerySizeFilter.landscape => p.aspectRatio >= 1.2,
        GallerySizeFilter.portrait => p.aspectRatio <= 0.85,
        GallerySizeFilter.square => p.aspectRatio > 0.85 && p.aspectRatio < 1.2,
      };
      final matchesFav = !_favoritesOnly || _favoriteIds.contains(p.id);
      return matchesQuery && matchesSize && matchesFav;
    }).toList();
  }

  void _toggleSelection(int id) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) {
          _multiSelectMode = false;
        }
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _enterMultiSelect(ImagePost post) {
    HapticFeedback.mediumImpact();
    setState(() {
      _multiSelectMode = true;
      _selectedIds.add(post.id);
    });
  }

  void _exitMultiSelect() {
    HapticFeedback.selectionClick();
    setState(() {
      _multiSelectMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _batchEvict() async {
    final posts = _posts.where((p) => _selectedIds.contains(p.id)).toList();
    for (final p in posts) {
      await Pixa.evict(PixaRequest.network(p.imageUrl));
    }
    _showSnack('Evicted ${posts.length} images from cache');
    _exitMultiSelect();
  }

  Future<void> _batchPrefetch() async {
    final posts = _posts.where((p) => _selectedIds.contains(p.id)).toList();
    final targetPixels = targetPixelsForLayout(_layout, _targetRowHeight);
    for (final p in posts) {
      await Pixa.prefetch(
        PixaRequest.network(
          p.imageUrl,
          targetSize: PixaTargetSize(width: targetPixels, height: targetPixels),
          cachePolicy: const PixaCachePolicy.public(maxAge: Duration(days: 7)),
          priority: PixaPriority.low,
        ),
        target: PixaPrefetchTarget.diskOnly,
      );
    }
    _showSnack('Prefetched ${posts.length} images to disk cache');
    _exitMultiSelect();
  }

  void _selectAll() {
    HapticFeedback.selectionClick();
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(_filteredPosts.map((p) => p.id));
    });
  }

  void _invertSelection() {
    HapticFeedback.selectionClick();
    final current = <int>{..._selectedIds};
    setState(() {
      _selectedIds.clear();
      for (final p in _filteredPosts) {
        if (!current.contains(p.id)) {
          _selectedIds.add(p.id);
        }
      }
    });
  }

  Future<void> _copySelectedIds() async {
    final ids = _selectedIds.toList()..sort();
    await Clipboard.setData(ClipboardData(text: ids.join(', ')));
    _showSnack('Copied ${ids.length} IDs to clipboard');
    _exitMultiSelect();
  }

  Future<void> _loadFirst() async {
    if (_posts.isNotEmpty) {
      return;
    }
    await _load(reset: true);
  }

  Future<void> _loadMore() async {
    await _load(reset: false);
  }

  Future<void> _load({required bool reset}) async {
    if (_isLoading) {
      return;
    }
    setState(() {
      _isLoading = true;
      if (reset) {
        _error = null;
      }
    });
    final int page = reset ? 1 : _currentPage + 1;
    try {
      final ImageSource sourceImpl = ImageSourceFactory.create(_source);
      final List<ImagePost> fetched = await sourceImpl.fetchPosts(
        page: page,
        limit: ImageConfig.defaultLimit,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        if (reset) {
          _posts = fetched;
          _currentPage = 1;
        } else {
          final Set<int> ids = _posts.map((ImagePost p) => p.id).toSet();
          for (final ImagePost p in fetched) {
            if (!ids.contains(p.id)) {
              _posts.add(p);
            }
          }
          _currentPage = page;
        }
        _hasMore = fetched.isNotEmpty;
        _isLoading = false;
        _error = null;
        _offlineMode = false;
      });
      widget.onPostsChanged?.call(List<ImagePost>.of(_posts));
      _prefetcher.clearHistory();
      // Pre-warm: after the first page loads, precache decoded images for the
      // first few visible tiles so the first frame after the skeleton dismisses
      // already has decoded images in Flutter's ImageCache. This eliminates the
      // placeholder→spinner→image flash on cold start.
      if (reset && mounted) {
        _prewarmVisibleTiles(fetched);
      }
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        if (reset) {
          _error = error.toString();
          // If we already have cached posts, mark offline mode rather than
          // showing a full-screen error — the user can still browse cached
          // images.
          _offlineMode = _posts.isNotEmpty;
        }
      });
    }
  }

  /// Pre-warms decoded images for the first few posts by precaching them into
  /// Flutter's ImageCache. Called after the initial feed loads so the visible
  /// tiles render without a placeholder flash on the first frame.
  void _prewarmVisibleTiles(List<ImagePost> posts) {
    final targetPixels = targetPixelsForLayout(_layout, _targetRowHeight);
    final count = posts.length < 6 ? posts.length : 6;
    for (var i = 0; i < count; i++) {
      final request = PixaRequest.network(
        posts[i].imageUrl,
        targetSize: PixaTargetSize(
          width: targetPixels,
          height:
              (targetPixels /
                      (posts[i].aspectRatio > 0 ? posts[i].aspectRatio : 1))
                  .round(),
        ),
        cachePolicy: const PixaCachePolicy.public(maxAge: Duration(days: 7)),
        priority: PixaPriority.high,
      );
      Pixa.precache(context, request).catchError((_) {});
    }
  }

  Future<void> _changeSource(SourceType source) async {
    setState(() {
      _source = source;
      ImageConfig.currentSource = source;
      _posts = <ImagePost>[];
      _hasMore = true;
      _currentPage = 1;
      _error = null;
    });
    await _load(reset: true);
  }

  Future<void> _prefetchWindow() async {
    if (_posts.isEmpty) {
      return;
    }
    final int forward = _prefetcher.forwardItemCount;
    for (var i = 0; i < forward && i < _posts.length; i += 1) {
      final PixaRequest? request = prefetchRequestForIndex(
        _posts,
        i,
        _layout,
        _targetRowHeight,
      );
      if (request == null) {
        continue;
      }
      await Pixa.prefetch(request, target: PixaPrefetchTarget.diskOnly);
    }
    if (mounted) {
      _showSnack('Prefetched $forward ${_source.name} images');
    }
  }

  Future<void> _trimMemory() async {
    await Pixa.trimMemory();
    if (mounted) {
      _showSnack('Memory trimmed');
    }
  }

  void _showCacheStats() {
    final PixaCacheStats stats = Pixa.cacheStats();
    final PixaDecodedCacheStats decoded = Pixa.decodedCacheStats();
    _showSnack(
      'Memory ${formatBytesLocal(stats.memoryBytes)} · '
      '${(stats.hitRate * 100).toStringAsFixed(1)}% hit · '
      '${decoded.currentSize}/${decoded.maximumSize} decoded',
    );
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  void _openLargeImage(ImagePost post) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => LargeImagePage(
          post: post,
          isFavorite: _favoriteIds.contains(post.id),
          onToggleFavorite: () => _toggleFavorite(post.id),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final PixaDebugSnapshot snapshot = PixaDebugInspector.snapshot();
    final bool empty = _posts.isEmpty;
    final List<ImagePost> filtered = _filteredPosts;
    final bool noResults = !empty && filtered.isEmpty;
    return NeuRefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification notification) {
          if (notification is ScrollStartNotification) {
            FocusScope.of(context).unfocus();
          }
          return false;
        },
        child: CustomScrollView(
          key: const ValueKey<String>('pixa-gallery-scroll'),
          controller: _scrollController,
          scrollCacheExtent: const ScrollCacheExtent.pixels(320),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            GalleryWorkbench(
              snapshot: snapshot,
              selectedSource: _source,
              onSourceChanged: _changeSource,
              layout: _layout,
              onLayoutChanged: (GalleryLayout l) => setState(() => _layout = l),
              targetRowHeight: _targetRowHeight,
              onTargetRowHeightChanged: (double v) =>
                  setState(() => _targetRowHeight = v),
              onPrefetch: _prefetchWindow,
              onCacheStats: _showCacheStats,
              onTrimMemory: _trimMemory,
            ),
            if (!empty)
              SliverToBoxAdapter(
                child: _GallerySearchBar(
                  query: _searchQuery,
                  onQueryChanged: (v) => setState(() => _searchQuery = v),
                  sizeFilter: _sizeFilter,
                  onSizeFilterChanged: (f) => setState(() => _sizeFilter = f),
                  resultCount: filtered.length,
                  offlineMode: _offlineMode,
                  favoritesOnly: _favoritesOnly,
                  onToggleFavorites: true,
                  favoriteCount: _favoriteIds.length,
                  onFavoriteToggle: () =>
                      setState(() => _favoritesOnly = !_favoritesOnly),
                ),
              ),
            if (_error != null && empty)
              GalleryErrorState(
                message: _error!,
                onRetry: () => _load(reset: true),
              )
            else if (empty && _isLoading)
              GalleryLoadingSliver(
                layout: _layout,
                targetRowHeight: _targetRowHeight,
              )
            else if (noResults)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'No images match "$_searchQuery".\nTry a different query or filter.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.neu.textMuted,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              )
            else ...<Widget>[
              _buildFeedSliver(filtered),
              GalleryLoadMoreBar(loading: _isLoading),
            ],
            // Batch action bar in multi-select mode.
            if (_multiSelectMode)
              SliverToBoxAdapter(
                child: _BatchActionBar(
                  count: _selectedIds.length,
                  totalCount: _filteredPosts.length,
                  onClear: _exitMultiSelect,
                  onEvict: _batchEvict,
                  onCopyIds: _copySelectedIds,
                  onPrefetch: _batchPrefetch,
                  onSelectAll: _selectAll,
                  onInvert: _invertSelection,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeedSliver(List<ImagePost> posts) {
    final int targetPixels = targetPixelsForLayout(_layout, _targetRowHeight);
    void Function(ImagePost) onTap = _multiSelectMode
        ? (p) => _toggleSelection(p.id)
        : _openLargeImage;
    switch (_layout) {
      case GalleryLayout.flexRows:
        return GalleryFlexRowsSliver(
          posts: posts,
          targetPixels: targetPixels,
          targetRowHeight: _targetRowHeight,
          searchQuery: _searchQuery,
          selectedIds: _selectedIds,
          multiSelectMode: _multiSelectMode,
          favoriteIds: _favoriteIds,
          onToggleFavorite: (p) => _toggleFavorite(p.id),
          onTapPost: onTap,
          onLongPressPost: _enterMultiSelect,
        );
      case GalleryLayout.masonry:
        return GalleryMasonrySliver(
          posts: posts,
          targetPixels: targetPixels,
          maxCrossAxisExtent: (_targetRowHeight * 1.28).clamp(150, 360),
          searchQuery: _searchQuery,
          selectedIds: _selectedIds,
          multiSelectMode: _multiSelectMode,
          favoriteIds: _favoriteIds,
          onToggleFavorite: (p) => _toggleFavorite(p.id),
          onTapPost: onTap,
          onLongPressPost: _enterMultiSelect,
        );
      case GalleryLayout.denseGrid:
        return GalleryDenseGridSliver(
          posts: posts,
          targetPixels: targetPixels,
          maxCrossAxisExtent: (_targetRowHeight * 1.1).clamp(128, 300),
          searchQuery: _searchQuery,
          selectedIds: _selectedIds,
          multiSelectMode: _multiSelectMode,
          favoriteIds: _favoriteIds,
          onToggleFavorite: (p) => _toggleFavorite(p.id),
          onTapPost: onTap,
          onLongPressPost: _enterMultiSelect,
        );
    }
  }
}

/// Size-based filter options for the gallery search/filter bar.
enum GallerySizeFilter { all, landscape, portrait, square }

/// A neumorphic search bar with size-filter chips and a result counter.
///
/// Lets the user filter the gallery feed by text query (id, source name,
/// dimensions, URL) and by aspect-ratio bucket (all / landscape / portrait /
/// square). The result count updates live as the user types.
class _GallerySearchBar extends StatelessWidget {
  const _GallerySearchBar({
    required this.query,
    required this.onQueryChanged,
    required this.sizeFilter,
    required this.onSizeFilterChanged,
    required this.resultCount,
    this.offlineMode = false,
    this.favoritesOnly = false,
    this.onToggleFavorites = false,
    this.favoriteCount = 0,
    this.onFavoriteToggle,
  });

  final String query;
  final ValueChanged<String> onQueryChanged;
  final GallerySizeFilter sizeFilter;
  final ValueChanged<GallerySizeFilter> onSizeFilterChanged;
  final int resultCount;
  final bool offlineMode;
  final bool favoritesOnly;
  final bool onToggleFavorites;
  final int favoriteCount;
  final VoidCallback? onFavoriteToggle;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: NeuCard(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Search field.
            TextField(
              onChanged: onQueryChanged,
              textInputAction: TextInputAction.search,
              style: TextStyle(color: palette.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search by ID, source, or size…',
                hintStyle: TextStyle(color: palette.textMuted, fontSize: 13),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: palette.textSecondary,
                  size: 20,
                ),
                suffixIcon: query.isNotEmpty
                    ? IconButton(
                        icon: Icon(
                          Icons.clear_rounded,
                          color: palette.textMuted,
                          size: 18,
                        ),
                        onPressed: () {
                          HapticFeedback.selectionClick();
                          onQueryChanged('');
                        },
                      )
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 6,
                ),
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            // Size filter chips + result count + offline badge.
            Row(
              children: <Widget>[
                if (offlineMode) ...<Widget>[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: ShapeDecoration(
                      color: palette.warning.withValues(alpha: 0.15),
                      shape: const RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.wifi_off_rounded,
                          size: 12,
                          color: palette.warning,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Offline · cached',
                          style: TextStyle(
                            color: palette.warning,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                for (final f in GallerySizeFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _FilterChip(
                      label: f.name,
                      selected: sizeFilter == f,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onSizeFilterChanged(f);
                      },
                    ),
                  ),
                const Spacer(),
                if (onToggleFavorites)
                  _FilterChip(
                    label: '★ $favoriteCount',
                    selected: favoritesOnly,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      onFavoriteToggle?.call();
                    },
                  ),
                Text(
                  '$resultCount',
                  style: TextStyle(
                    color: palette.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: ShapeDecoration(
          color: selected ? palette.accentSoft : palette.base,
          shape: const RoundedSuperellipseBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
        ),
        child: Text(
          label[0].toUpperCase() + label.substring(1),
          style: TextStyle(
            color: selected ? palette.accent : palette.textSecondary,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// A floating batch action bar shown when multi-select is active.
class _BatchActionBar extends StatelessWidget {
  const _BatchActionBar({
    required this.count,
    required this.totalCount,
    required this.onClear,
    required this.onEvict,
    required this.onCopyIds,
    required this.onPrefetch,
    required this.onSelectAll,
    required this.onInvert,
  });

  final int count;
  final int totalCount;
  final VoidCallback onClear;
  final VoidCallback onEvict;
  final VoidCallback onCopyIds;
  final VoidCallback onPrefetch;
  final VoidCallback onSelectAll;
  final VoidCallback onInvert;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    final allSelected = count >= totalCount && totalCount > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: NeuCard(
        elevation: NeuElevation.medium,
        shape: NeuShape.convex,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: <Widget>[
            Text(
              '$count/$totalCount',
              style: TextStyle(
                color: palette.accent,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: <Widget>[
                  NeuButton(
                    onPressed: onSelectAll,
                    icon: Icon(
                      allSelected
                          ? Icons.deselect_rounded
                          : Icons.select_all_rounded,
                      size: 16,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Text(allSelected ? 'Deselect all' : 'Select all'),
                  ),
                  NeuIconButton(
                    icon: Icons.swap_horiz_rounded,
                    tooltip: 'Invert selection',
                    size: 34,
                    iconSize: 16,
                    onPressed: onInvert,
                  ),
                  NeuButton(
                    onPressed: onCopyIds,
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: const Text('Copy IDs'),
                  ),
                  NeuButton(
                    onPressed: onPrefetch,
                    icon: const Icon(Icons.download_rounded, size: 16),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: const Text('Prefetch'),
                  ),
                  NeuButton(
                    onPressed: onEvict,
                    icon: const Icon(Icons.delete_outline_rounded, size: 16),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: const Text('Evict'),
                  ),
                  NeuIconButton(
                    icon: Icons.close_rounded,
                    tooltip: 'Clear selection',
                    size: 36,
                    iconSize: 16,
                    onPressed: onClear,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String formatBytesLocal(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  }
  return '$bytes B';
}
