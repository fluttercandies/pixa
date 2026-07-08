import 'package:flexbox_layout/flexbox_layout.dart';
import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';

import '../models/image_post.dart';
import '../pixa/pixa_recipes.dart';
import 'gallery_tile.dart';

/// Layout modes the gallery can render.
enum GalleryLayout { flexRows, masonry, denseGrid }

/// Flex-row sliver: targets a row height and lets each tile fill by aspect
/// ratio.
class GalleryFlexRowsSliver extends StatelessWidget {
  const GalleryFlexRowsSliver({
    super.key,
    required this.posts,
    required this.targetPixels,
    required this.targetRowHeight,
    required this.onTapPost,
    this.searchQuery = '',
    this.selectedIds,
    this.multiSelectMode = false,
    this.onLongPressPost,
    this.favoriteIds,
    this.onToggleFavorite,
  });

  final List<ImagePost> posts;
  final int targetPixels;
  final double targetRowHeight;
  final void Function(ImagePost post) onTapPost;
  final String searchQuery;
  final Set<int>? selectedIds;
  final bool multiSelectMode;
  final void Function(ImagePost post)? onLongPressPost;
  final Set<int>? favoriteIds;
  final void Function(ImagePost post)? onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      sliver: SliverFlexbox(
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) {
            final ImagePost post = posts[index];
            return GalleryTile(
              key: ValueKey<String>('flex-${post.id}'),
              post: post,
              targetPixels: targetPixels,
              searchQuery: searchQuery,
              selected: selectedIds?.contains(post.id) ?? false,
              multiSelectMode: multiSelectMode,
              isFavorite: favoriteIds?.contains(post.id) ?? false,
              onToggleFavorite: onToggleFavorite != null
                  ? () => onToggleFavorite!(post)
                  : null,
              onTap: () => onTapPost(post),
              onLongPress: onLongPressPost != null
                  ? () => onLongPressPost!(post)
                  : null,
            );
          },
          childCount: posts.length,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: false,
          addSemanticIndexes: false,
        ),
        flexboxDelegate: SliverFlexboxDelegateWithAspectRatios(
          aspectRatios: posts
              .map((ImagePost p) => p.aspectRatio)
              .toList(growable: false),
          targetRowHeight: targetRowHeight,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
      ),
    );
  }
}

/// Masonry sliver: columns sized by max cross-axis extent.
class GalleryMasonrySliver extends StatelessWidget {
  const GalleryMasonrySliver({
    super.key,
    required this.posts,
    required this.targetPixels,
    required this.maxCrossAxisExtent,
    required this.onTapPost,
    this.searchQuery = '',
    this.selectedIds,
    this.multiSelectMode = false,
    this.onLongPressPost,
    this.favoriteIds,
    this.onToggleFavorite,
  });

  final List<ImagePost> posts;
  final int targetPixels;
  final double maxCrossAxisExtent;
  final String searchQuery;
  final Set<int>? selectedIds;
  final bool multiSelectMode;
  final void Function(ImagePost post)? onLongPressPost;
  final Set<int>? favoriteIds;
  final void Function(ImagePost post)? onToggleFavorite;
  final void Function(ImagePost post) onTapPost;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      sliver: SliverMasonryFlexbox(
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) {
            final ImagePost post = posts[index];
            return GalleryTile(
              key: ValueKey<String>('masonry-${post.id}'),
              post: post,
              targetPixels: targetPixels,
              searchQuery: searchQuery,
              selected: selectedIds?.contains(post.id) ?? false,
              multiSelectMode: multiSelectMode,
              isFavorite: favoriteIds?.contains(post.id) ?? false,
              onToggleFavorite: onToggleFavorite != null
                  ? () => onToggleFavorite!(post)
                  : null,
              onTap: () => onTapPost(post),
              onLongPress: onLongPressPost != null
                  ? () => onLongPressPost!(post)
                  : null,
            );
          },
          childCount: posts.length,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: false,
          addSemanticIndexes: false,
        ),
        masonryDelegate: SliverMasonryFlexboxDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: maxCrossAxisExtent,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childMainAxisExtentBuilder: (int index, double childCrossAxisExtent) {
            // Give each cell a height proportional to its aspect ratio so
            // masonry varies naturally without measuring intrinsic images.
            final ImagePost p = posts[index];
            final double ratio = p.aspectRatio > 0 ? p.aspectRatio : 1;
            return (childCrossAxisExtent / ratio).clamp(120, 360);
          },
        ),
      ),
    );
  }
}

/// Dense grid sliver: square tiles. Tiles are keyed `grid-${id}` so the
/// large-image route tap can target them.
class GalleryDenseGridSliver extends StatelessWidget {
  const GalleryDenseGridSliver({
    super.key,
    required this.posts,
    required this.targetPixels,
    required this.maxCrossAxisExtent,
    required this.onTapPost,
    this.searchQuery = '',
    this.selectedIds,
    this.multiSelectMode = false,
    this.onLongPressPost,
    this.favoriteIds,
    this.onToggleFavorite,
  });

  final List<ImagePost> posts;
  final int targetPixels;
  final double maxCrossAxisExtent;
  final String searchQuery;
  final Set<int>? selectedIds;
  final bool multiSelectMode;
  final void Function(ImagePost post)? onLongPressPost;
  final Set<int>? favoriteIds;
  final void Function(ImagePost post)? onToggleFavorite;
  final void Function(ImagePost post) onTapPost;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: maxCrossAxisExtent,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1,
        ),
        delegate: SliverChildBuilderDelegate(
          (BuildContext context, int index) {
            final ImagePost post = posts[index];
            return GalleryTile(
              key: ValueKey<String>('grid-${post.id}'),
              post: post,
              targetPixels: targetPixels,
              searchQuery: searchQuery,
              selected: selectedIds?.contains(post.id) ?? false,
              multiSelectMode: multiSelectMode,
              isFavorite: favoriteIds?.contains(post.id) ?? false,
              onToggleFavorite: onToggleFavorite != null
                  ? () => onToggleFavorite!(post)
                  : null,
              onTap: () => onTapPost(post),
              onLongPress: onLongPressPost != null
                  ? () => onLongPressPost!(post)
                  : null,
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

/// Computes a per-layout target pixel budget for the visible tiles.
int targetPixelsForLayout(GalleryLayout layout, double targetRowHeight) {
  switch (layout) {
    case GalleryLayout.flexRows:
      return (targetRowHeight * 2.2).round();
    case GalleryLayout.masonry:
      return (targetRowHeight * 2.0).round();
    case GalleryLayout.denseGrid:
      return (targetRowHeight * 1.65).round();
  }
}

/// Builds a [PixaRequest] for a post in the visible range, used by the
/// predictive prefetcher.
PixaRequest? prefetchRequestForIndex(
  List<ImagePost> posts,
  int index,
  GalleryLayout layout,
  double targetRowHeight,
) {
  if (index < 0 || index >= posts.length) {
    return null;
  }
  return postRequest(
    posts[index],
    targetPixels: targetPixelsForLayout(layout, targetRowHeight),
  );
}
