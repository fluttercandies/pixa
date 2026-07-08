import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pixa/pixa.dart';

import '../models/image_post.dart';
import '../pixa/pixa_recipes.dart';
import '../theme/neu_palette.dart';
import '../widgets/neu_surface.dart';

/// A single image tile for the gallery grid / masonry / flex layouts.
///
/// Builds a layout-aware [PixaRequest] from the [post] and the available
/// tile pixels, then renders the image inside a clipped neumorphic well so
/// the photo sits in a soft cavity. Tap opens the large-image route.
class GalleryTile extends StatefulWidget {
  const GalleryTile({
    super.key,
    required this.post,
    required this.targetPixels,
    required this.onTap,
    this.onLongPress,
    this.showLabel = false,
    this.searchQuery = '',
    this.selected = false,
    this.multiSelectMode = false,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
  });

  final ImagePost post;
  final int targetPixels;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool showLabel;
  final bool selected;
  final bool multiSelectMode;
  final String searchQuery;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;
  final BorderRadius borderRadius;

  @override
  State<GalleryTile> createState() => GalleryTileState();
}

@visibleForTesting
class GalleryTileState extends State<GalleryTile> {
  PixaRequest? _request;
  int _lastPixels = -1;

  /// Lazily resolves and memoizes the layout-aware request.
  PixaRequest requestForTile() {
    if (_request != null && _lastPixels == widget.targetPixels) {
      return _request!;
    }
    _request = postRequest(widget.post, targetPixels: widget.targetPixels);
    _lastPixels = widget.targetPixels;
    return _request!;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    final tileContent = Semantics(
      button: true,
      label:
          '${widget.multiSelectMode ? "Select" : "Open"} image ${widget.post.id} from ${widget.post.source.name}',
      child: NeuSurface(
        onTap: () {
          if (!widget.multiSelectMode) HapticFeedback.lightImpact();
          widget.onTap();
        },
        onLongPress: widget.onLongPress,
        shape: widget.selected ? NeuShape.concave : NeuShape.convex,
        elevation: NeuElevation.low,
        color: widget.selected ? palette.accentSoft : palette.surface,
        borderRadius: widget.borderRadius,
        padding: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Positioned.fill(
              child: PixaImage(
                request: requestForTile(),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.none,
                semanticLabel:
                    'Image ${widget.post.id} from ${widget.post.source.name}',
                placeholder: PixaPlaceholder.color(palette.surface),
                progressBuilder: pixaTileProgressBuilder,
                errorBuilder: pixaErrorBuilder,
                transitionDuration: const Duration(milliseconds: 220),
              ),
            ),
            if (widget.multiSelectMode)
              Positioned(
                top: 6,
                right: 6,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: widget.selected
                      ? Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: palette.accent,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.check_rounded,
                            color: palette.onAccent,
                            size: 16,
                          ),
                        )
                      : Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: palette.overlayScrim,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.circle_outlined,
                            color: palette.surface,
                            size: 16,
                          ),
                        ),
                ),
              ),
            if (widget.isFavorite && !widget.multiSelectMode)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: palette.warning.withValues(alpha: 0.9),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.star_rounded,
                    color: Colors.white,
                    size: 14,
                  ),
                ),
              ),
            if (widget.showLabel || widget.searchQuery.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[
                          Colors.transparent,
                          palette.overlayScrim,
                        ],
                      ),
                    ),
                    child: _SearchLabel(
                      text: '${widget.post.source.name} · #${widget.post.id}',
                      query: widget.searchQuery,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    // When not in multi-select, wrap with horizontal swipe gestures:
    // swipe-left = toggle favorite, swipe-right = no-op (reserved).
    if (widget.multiSelectMode) {
      return RepaintBoundary(child: tileContent);
    }
    return RepaintBoundary(
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          if (details.primaryVelocity == null) return;
          final v = details.primaryVelocity!;
          // Swipe left (negative velocity) = toggle favorite
          if (v < -300 && widget.onToggleFavorite != null) {
            HapticFeedback.selectionClick();
            widget.onToggleFavorite!();
          }
        },
        behavior: HitTestBehavior.translucent,
        child: tileContent,
      ),
    );
  }
}

/// Renders a label text with the matching [query] substring highlighted in
/// the accent colour, so search results visually confirm what matched.
class _SearchLabel extends StatelessWidget {
  const _SearchLabel({required this.text, required this.query});

  final String text;
  final String query;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    final baseStyle = TextStyle(
      color: palette.surface,
      fontSize: 11,
      fontWeight: FontWeight.w700,
    );
    if (query.isEmpty) {
      return Text(
        text,
        style: baseStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    final lower = text.toLowerCase();
    final q = query.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (start < text.length) {
      final idx = lower.indexOf(q, start);
      if (idx < 0) {
        spans.add(TextSpan(text: text.substring(start), style: baseStyle));
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(text: text.substring(start, idx), style: baseStyle));
      }
      spans.add(
        TextSpan(
          text: text.substring(idx, idx + q.length),
          style: baseStyle.copyWith(
            color: palette.accent,
            backgroundColor: palette.accent.withValues(alpha: 0.3),
          ),
        ),
      );
      start = idx + q.length;
    }
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(children: spans, style: baseStyle),
    );
  }
}
