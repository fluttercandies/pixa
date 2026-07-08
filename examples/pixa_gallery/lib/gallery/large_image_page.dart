import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pixa/pixa.dart';

import '../models/image_post.dart';
import '../pixa/pixa_recipes.dart';
import '../theme/neu_palette.dart';
import '../widgets/neu_controls.dart';
import '../widgets/neu_surface.dart';

/// Full-screen large-image route.
///
/// Picks between the tiled [PixaLargeImage] viewer, a direct overview, or
/// an overview-only fallback based on the post dimensions and runtime
/// region-decode capability.
class LargeImagePage extends StatefulWidget {
  const LargeImagePage({
    super.key,
    required this.post,
    this.isFavorite = false,
    this.onToggleFavorite,
  });

  final ImagePost post;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;

  @override
  State<LargeImagePage> createState() => _LargeImagePageState();
}

class _LargeImagePageState extends State<LargeImagePage>
    with SingleTickerProviderStateMixin {
  final PixaLargeImageController _controller = PixaLargeImageController();
  final TransformationController _overviewController =
      TransformationController();
  // Drives smooth animated zoom / reset on the overview path.
  AnimationController? _matrixAnim;
  Animation<Matrix4>? _matrixTween;

  // EXIF/metadata info panel state.
  bool _showInfo = false;
  PixaImageMetadata? _meta;
  int _metaBytes = 0;
  bool _metaLoading = false;

  @override
  void dispose() {
    _matrixAnim?.dispose();
    _controller.dispose();
    _overviewController.dispose();
    super.dispose();
  }

  Future<void> _probeMetadata() async {
    if (_meta != null || _metaLoading) {
      return;
    }
    setState(() => _metaLoading = true);
    try {
      final load = await Pixa.pipeline.load(
        PixaRequest.network(
          widget.post.imageUrl,
          cachePolicy: const PixaCachePolicy.cacheOnly(),
          priority: PixaPriority.high,
        ),
      );
      try {
        final m = PixaImageMetadata.parseEncoded(load.bytes);
        if (mounted) {
          setState(() {
            _meta = m;
            _metaBytes = load.bytes.length;
            _metaLoading = false;
          });
        }
      } finally {
        load.dispose();
      }
    } on Object {
      if (mounted) {
        setState(() => _metaLoading = false);
      }
    }
  }

  bool get _useTiled => postNeedsTiledViewer(widget.post);
  bool get _overviewOnly => postNeedsOverviewOnly(widget.post);

  /// Animates the overview transform from its current value to [target] over
  /// 300ms with an ease-out curve, so fit / zoom / reset feel smooth instead
  void _shareImage() {
    HapticFeedback.selectionClick();
    final post = widget.post;
    final text = StringBuffer()
      ..writeln('Pixa Gallery · ${post.source.name} · #${post.id}')
      ..writeln('URL: ${post.imageUrl}')
      ..writeln('Dimensions: ${post.width}×${post.height}');
    if (_meta != null) {
      text
        ..writeln('Format: ${_meta!.format.name.toUpperCase()}')
        ..writeln('Animated: ${_meta!.isAnimated ? "yes" : "no"}')
        ..writeln('Progressive: ${_meta!.isProgressive ? "yes" : "no"}');
    }
    text.writeln('Encoded: ${formatBytes(_metaBytes)}');
    Clipboard.setData(ClipboardData(text: text.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Image info copied to clipboard'),
          duration: const Duration(seconds: 2),
          backgroundColor: context.neu.accent,
        ),
      );
    }
  }

  /// of snapping the matrix.
  void _animateOverviewTo(Matrix4 target) {
    _matrixAnim?.dispose();
    _matrixAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _matrixTween =
        Matrix4Tween(
          begin: Matrix4.copy(_overviewController.value),
          end: target,
        ).animate(
          CurvedAnimation(parent: _matrixAnim!, curve: Curves.easeOutCubic),
        );
    _matrixTween!.addListener(() {
      _overviewController.value = _matrixTween!.value;
    });
    _matrixAnim!.forward();
  }

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return Scaffold(
      backgroundColor: palette.base,
      appBar: NeuAppBar(
        title: Text(
          '${widget.post.source.name} · #${widget.post.id}',
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        leading: NeuIconButton(
          icon: Icons.arrow_back_rounded,
          tooltip: 'Back',
          size: 46,
          iconSize: 20,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: <Widget>[
          if (widget.onToggleFavorite != null)
            NeuIconButton(
              icon: widget.isFavorite
                  ? Icons.star_rounded
                  : Icons.star_border_rounded,
              tooltip: widget.isFavorite ? 'Unfavorite' : 'Favorite',
              size: 46,
              iconSize: 20,
              selected: widget.isFavorite,
              onPressed: () {
                HapticFeedback.selectionClick();
                widget.onToggleFavorite!();
              },
            ),
          if (_useTiled || _overviewOnly) _buildFitButton(palette),
          if (_useTiled || _overviewOnly)
            NeuIconButton(
              icon: Icons.zoom_in_rounded,
              tooltip: 'Zoom 200%',
              size: 46,
              iconSize: 20,
              onPressed: () => _zoomTo(2.0),
            ),
          if (_useTiled || _overviewOnly)
            NeuIconButton(
              icon: Icons.crop_free_rounded,
              tooltip: 'Reset',
              size: 46,
              iconSize: 20,
              onPressed: _reset,
            ),
          NeuIconButton(
            icon: Icons.info_outline_rounded,
            tooltip: 'Image info',
            size: 46,
            iconSize: 20,
            selected: _showInfo,
            onPressed: () {
              HapticFeedback.selectionClick();
              setState(() => _showInfo = !_showInfo);
              if (_showInfo) {
                _probeMetadata();
              }
            },
          ),
          NeuIconButton(
            icon: Icons.ios_share_rounded,
            tooltip: 'Share',
            size: 46,
            iconSize: 20,
            onPressed: _shareImage,
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          _useTiled ? _buildTiledViewer() : _buildOverviewViewer(palette),
          if (_showInfo)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: _ImageInfoPanel(
                post: widget.post,
                metadata: _meta,
                bytes: _metaBytes,
                loading: _metaLoading,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFitButton(NeuPalette palette) {
    return NeuIconButton(
      icon: Icons.fit_screen_outlined,
      tooltip: 'Fit',
      size: 46,
      iconSize: 20,
      onPressed: () => _zoomTo(1.0),
    );
  }

  Widget _buildTiledViewer() {
    final PixaRequest request = postRequest(
      widget.post,
      targetPixels: 768,
    ).copyWith(lowRes: lowResRequest(widget.post, pixels: 24));
    return PixaLargeImage(
      request: request,
      imageWidth: widget.post.width > 0 ? widget.post.width : 1024,
      imageHeight: widget.post.height > 0 ? widget.post.height : 1024,
      controller: _controller,
      tileMode: PixaLargeImageTileMode.adaptive,
      maxScale: 4,
      tileSize: 512,
      cacheExtentScreens: 1.25,
      maxVisibleTiles: 80,
      backgroundColor: context.neu.base,
      placeholder: PixaPlaceholder.color(context.neu.surface),
      progressBuilder: pixaProgressBuilder,
      errorBuilder: pixaErrorBuilder,
      tileErrorBuilder: pixaTileErrorBuilder,
    );
  }

  Widget _buildOverviewViewer(NeuPalette palette) {
    return Stack(
      children: <Widget>[
        Positioned.fill(child: ColoredBox(color: palette.base)),
        // Double-tap to toggle zoom is a standard photo-viewer affordance.
        GestureDetector(
          onDoubleTap: _onDoubleTap,
          behavior: HitTestBehavior.translucent,
          child: InteractiveViewer(
            transformationController: _overviewController,
            minScale: 1,
            maxScale: 4,
            child: Center(
              child: PixaImage(
                request: postRequest(widget.post, targetPixels: 1280),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                semanticLabel:
                    'Large image ${widget.post.id} from ${widget.post.source.name}',
                placeholder: PixaPlaceholder.color(palette.surface),
                progressBuilder: pixaProgressBuilder,
                errorBuilder: pixaErrorBuilder,
              ),
            ),
          ),
        ),
        if (_overviewOnly)
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(child: _OverviewBadge()),
          ),
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: Center(child: _GestureHint()),
        ),
      ],
    );
  }

  void _zoomTo(double scale) {
    if (_useTiled) {
      _controller.zoomTo(scale);
    } else {
      final Matrix4 m = Matrix4.identity()
        ..scaleByDouble(scale, scale, 1.0, 1.0);
      _animateOverviewTo(m);
    }
  }

  /// Double-tap toggles between fit (1x) and a closer 2x view, animated.
  void _onDoubleTap() {
    HapticFeedback.selectionClick();
    final double currentScale = _overviewController.value.getMaxScaleOnAxis();
    if (currentScale > 1.05) {
      _animateOverviewTo(Matrix4.identity());
    } else {
      _zoomTo(2.0);
    }
  }

  void _reset() {
    if (_useTiled) {
      _controller.reset();
    } else {
      _animateOverviewTo(Matrix4.identity());
    }
  }
}

class _OverviewBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return NeuSurface(
      shape: NeuShape.convex,
      elevation: NeuElevation.low,
      borderRadius: BorderRadius.circular(20),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.info_outline_rounded, size: 14, color: palette.textMuted),
          const SizedBox(width: 6),
          Text(
            'Overview only · no region decoder',
            style: TextStyle(
              color: palette.textSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// A brief, auto-dismissing hint that surfaces the pinch / double-tap zoom
/// affordance so the gesture is discoverable on first open.
class _GestureHint extends StatefulWidget {
  @override
  State<_GestureHint> createState() => _GestureHintState();
}

class _GestureHintState extends State<_GestureHint> {
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _visible = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return AnimatedOpacity(
      opacity: _visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
      child: IgnorePointer(
        ignoring: !_visible,
        child: NeuSurface(
          shape: NeuShape.convex,
          elevation: NeuElevation.low,
          borderRadius: BorderRadius.circular(20),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.touch_app_rounded, size: 14, color: palette.accent),
              const SizedBox(width: 6),
              Text(
                'Pinch or double-tap to zoom',
                style: TextStyle(
                  color: palette.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A neumorphic bottom sheet showing the image's metadata (format, dimensions,
/// animated/progressive flags, encoded bytes, source). Uses
/// [PixaImageMetadata.parseEncoded] — the same API a host app would call.
class _ImageInfoPanel extends StatelessWidget {
  const _ImageInfoPanel({
    required this.post,
    required this.metadata,
    required this.bytes,
    required this.loading,
  });

  final ImagePost post;
  final PixaImageMetadata? metadata;
  final int bytes;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return NeuSurface(
      shape: NeuShape.convex,
      elevation: NeuElevation.medium,
      borderRadius: BorderRadius.circular(22),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.info_outline_rounded, color: palette.accent, size: 18),
              const SizedBox(width: 8),
              Text(
                'Image info',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              Text(
                '#${post.id}',
                style: TextStyle(
                  color: palette.textMuted,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Center(child: NeuSpinner(size: 20)),
            )
          else if (metadata != null)
            _InfoGrid(
              rows: <_InfoRow>[
                _InfoRow('Format', metadata!.format.name.toUpperCase()),
                _InfoRow(
                  'Dimensions',
                  '${metadata!.width}×${metadata!.height}',
                ),
                _InfoRow('Animated', metadata!.isAnimated ? 'yes' : 'no'),
                _InfoRow('Progressive', metadata!.isProgressive ? 'yes' : 'no'),
                _InfoRow('Encoded', formatBytes(bytes)),
                _InfoRow('Source', post.source.name),
              ],
            )
          else
            Text(
              'Metadata unavailable (image not in cache).',
              style: TextStyle(color: palette.textMuted, fontSize: 12),
            ),
        ],
      ),
    );
  }
}

class _InfoRow {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;
}

class _InfoGrid extends StatelessWidget {
  const _InfoGrid({required this.rows});
  final List<_InfoRow> rows;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return Wrap(
      runSpacing: 4,
      children: <Widget>[
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 90,
                  child: Text(
                    row.label,
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    row.value,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
