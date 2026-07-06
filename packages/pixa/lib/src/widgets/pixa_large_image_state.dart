part of 'pixa_large_image.dart';

final class _PixaLargeImageState extends State<PixaLargeImage>
    with SingleTickerProviderStateMixin {
  late PixaLargeImageController _controller;
  late final AnimationController _transformAnimationController;
  Animation<Matrix4>? _transformAnimation;
  bool _ownsController = false;
  Size? _lastViewportSize;
  Object? _lastImageIdentity;
  Offset? _lastDoubleTapPosition;
  Timer? _settleTimer;
  Timer? _prefetchTimer;
  String? _lastVisibleTileSignature;
  String? _lastPrefetchSignature;
  final Map<String, PixaRequest> _visibleTileRequests = <String, PixaRequest>{};

  @override
  void initState() {
    super.initState();
    _transformAnimationController = AnimationController(vsync: this)
      ..addListener(_handleTransformAnimationTick)
      ..addStatusListener(_handleTransformAnimationStatus);
    _attachController(widget.controller);
  }

  @override
  void didUpdateWidget(PixaLargeImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _detachController();
      _attachController(widget.controller);
    }
    final Object imageIdentity = _imageIdentity;
    if (_lastImageIdentity != imageIdentity) {
      _lastImageIdentity = imageIdentity;
      _lastViewportSize = null;
    }
  }

  @override
  void dispose() {
    _transformAnimationController.dispose();
    _settleTimer?.cancel();
    _prefetchTimer?.cancel();
    if (widget.evictDecodedTilesOnExit) {
      _evictDecodedRequests(_visibleTileRequests.values);
    }
    _detachController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PixaLargeImageTilePlanner planner = PixaLargeImageTilePlanner(
      imageSize: PixaLargeImageSize(
        width: widget.imageWidth,
        height: widget.imageHeight,
      ),
      tileSize: widget.tileSize,
      cacheExtentScreens: widget.cacheExtentScreens,
      maxVisibleTiles: widget.maxVisibleTiles,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size viewportSize = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 0,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 0,
        );
        _ensureInitialTransform(viewportSize);
        final double fitScale = _scaleFor(viewportSize, widget.fit);
        final double minScale = widget.minScale ?? fitScale;
        final PixaLargeImageTilePlan plan = planner.plan(
          transform: _controller._transform.value,
          viewportSize: viewportSize,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
        _syncTileLifecycle(plan);
        return ColoredBox(
          color: widget.backgroundColor,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTapDown: widget.doubleTapZoomEnabled
                ? _handleDoubleTapDown
                : null,
            onDoubleTap: widget.doubleTapZoomEnabled ? _handleDoubleTap : null,
            child: InteractiveViewer(
              transformationController: _controller._transform,
              minScale: math.max(0.000001, minScale),
              maxScale: math.max(widget.maxScale, minScale),
              boundaryMargin: EdgeInsets.all(
                math.max(widget.imageWidth, widget.imageHeight).toDouble(),
              ),
              constrained: false,
              clipBehavior: widget.clipBehavior,
              onInteractionStart: (_) => _stopTransformAnimation(),
              onInteractionUpdate: (_) => _fitCurrentTransformToBounds(),
              onInteractionEnd: (_) {
                _fitCurrentTransformToBounds();
                _scheduleSettle();
              },
              child: SizedBox(
                width: widget.imageWidth.toDouble(),
                height: widget.imageHeight.toDouble(),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (widget.showOverview) _buildOverview(),
                    for (final PixaLargeImageTile tile in plan.visibleTiles)
                      _TileImage(
                        key: ValueKey<String>(tile.key),
                        tile: tile,
                        request: tile.requestFor(widget.request),
                        filterQuality: widget.filterQuality,
                        errorBuilder: widget.errorBuilder,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Object get _imageIdentity => Object.hash(
    widget.request.cacheKey,
    widget.imageWidth,
    widget.imageHeight,
  );

  Widget _buildOverview() {
    final int width;
    final int height;
    if (widget.imageWidth >= widget.imageHeight) {
      width = widget.overviewTargetPixels;
      height = math.max(
        1,
        (widget.imageHeight * widget.overviewTargetPixels / widget.imageWidth)
            .round(),
      );
    } else {
      height = widget.overviewTargetPixels;
      width = math.max(
        1,
        (widget.imageWidth * widget.overviewTargetPixels / widget.imageHeight)
            .round(),
      );
    }
    return Positioned.fill(
      child: PixaImage(
        request: widget.request.copyWith(
          targetSize: PixaTargetSize(width: width, height: height),
          priority: PixaPriority.high,
        ),
        fit: BoxFit.fill,
        filterQuality: FilterQuality.low,
        placeholder: widget.placeholder,
        progressBuilder: widget.progressBuilder,
        errorBuilder: widget.errorBuilder,
        transitionDuration: Duration.zero,
      ),
    );
  }

  void _syncTileLifecycle(PixaLargeImageTilePlan plan) {
    final Map<String, PixaRequest> visible = <String, PixaRequest>{
      for (final PixaLargeImageTile tile in plan.visibleTiles)
        tile.key: tile.requestFor(widget.request),
    };
    final String visibleSignature = _signatureFor(visible.keys);
    if (visibleSignature != _lastVisibleTileSignature) {
      _lastVisibleTileSignature = visibleSignature;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final Iterable<PixaRequest> exited = _visibleTileRequests.entries
            .where(
              (MapEntry<String, PixaRequest> entry) =>
                  !visible.containsKey(entry.key),
            )
            .map((MapEntry<String, PixaRequest> entry) => entry.value)
            .toList(growable: false);
        _visibleTileRequests
          ..clear()
          ..addAll(visible);
        if (widget.evictDecodedTilesOnExit) {
          _evictDecodedRequests(exited);
        }
      });
    }
    _schedulePrefetch(plan);
  }

  void _schedulePrefetch(PixaLargeImageTilePlan plan) {
    if (!widget.prefetchTiles || widget.maxPrefetchTiles == 0) {
      _prefetchTimer?.cancel();
      _lastPrefetchSignature = null;
      return;
    }
    final List<PixaRequest> requests = <PixaRequest>[
      for (final PixaLargeImageTile tile in plan.prefetchTiles.take(
        widget.maxPrefetchTiles,
      ))
        tile.requestFor(widget.request),
    ];
    final String signature =
        '${widget.prefetchTarget.name}:'
        '${_signatureFor(requests.map((PixaRequest request) => request.cacheKey.value))}';
    if (signature == _lastPrefetchSignature) {
      return;
    }
    _lastPrefetchSignature = signature;
    _prefetchTimer?.cancel();
    if (requests.isEmpty) {
      return;
    }
    _prefetchTimer = Timer(const Duration(milliseconds: 90), () {
      if (!mounted || !Pixa.isConfigured) {
        return;
      }
      for (final PixaRequest request in requests) {
        unawaited(
          Pixa.prefetch(
            request,
            target: widget.prefetchTarget,
          ).catchError((Object _) {}),
        );
      }
    });
  }

  void _evictDecodedRequests(Iterable<PixaRequest> requests) {
    if (!Pixa.isConfigured) {
      return;
    }
    for (final PixaRequest request in requests) {
      unawaited(
        Pixa.evict(
          request,
          encoded: false,
          decoded: true,
        ).catchError((Object _) {}),
      );
    }
  }

  String _signatureFor(Iterable<String> keys) {
    return keys.join('|');
  }

  void _attachController(PixaLargeImageController? controller) {
    _ownsController = controller == null;
    _controller = controller ?? PixaLargeImageController();
    _controller._transform.addListener(_handleTransformChanged);
    _controller._resetHandler = _resetTransform;
    _controller._zoomToHandler = _zoomTo;
    _lastImageIdentity = _imageIdentity;
  }

  void _detachController() {
    _controller._transform.removeListener(_handleTransformChanged);
    _controller._resetHandler = null;
    _controller._zoomToHandler = null;
    if (_ownsController) {
      _controller.dispose();
    }
  }

  void _handleTransformChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _scheduleSettle() {
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 80), () {
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    _lastDoubleTapPosition = details.localPosition;
  }

  void _handleDoubleTap() {
    final Size? viewportSize = _lastViewportSize;
    if (viewportSize == null || viewportSize.isEmpty) {
      return;
    }
    final double minScale = _minScaleFor(viewportSize);
    final double maxScale = _maxScaleFor(viewportSize);
    final double zoomScale = widget.doubleTapZoomScale
        .clamp(minScale, maxScale)
        .toDouble();
    final double currentScale = _controller.scale;
    final bool zoomIn =
        currentScale <= zoomScale * 0.9 || _nearlyEqual(currentScale, minScale);
    final Offset focus =
        _lastDoubleTapPosition ??
        Offset(viewportSize.width / 2, viewportSize.height / 2);
    final Matrix4 target = _targetMatrixForScale(
      zoomIn ? zoomScale : minScale,
      focus,
      viewportSize,
    );
    _animateTransformTo(target, widget.doubleTapZoomDuration);
  }

  void _handleTransformAnimationTick() {
    final Matrix4? value = _transformAnimation?.value;
    if (value != null) {
      _controller._transform.value = value;
    }
  }

  void _handleTransformAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _transformAnimation = null;
      _fitCurrentTransformToBounds();
      _scheduleSettle();
    }
  }

  void _stopTransformAnimation() {
    if (_transformAnimationController.isAnimating) {
      _transformAnimationController.stop();
    }
    _transformAnimation = null;
  }

  void _animateTransformTo(Matrix4 target, Duration duration) {
    _stopTransformAnimation();
    if (duration == Duration.zero) {
      _controller._transform.value = target;
      _scheduleSettle();
      return;
    }
    _transformAnimationController.duration = duration;
    _transformAnimation =
        Matrix4Tween(
          begin: Matrix4.copy(_controller._transform.value),
          end: target,
        ).animate(
          CurvedAnimation(
            parent: _transformAnimationController,
            curve: Curves.easeOutCubic,
          ),
        );
    unawaited(_transformAnimationController.forward(from: 0));
  }

  void _ensureInitialTransform(Size viewportSize) {
    if (viewportSize.isEmpty || _lastViewportSize == viewportSize) {
      return;
    }
    _lastViewportSize = viewportSize;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _lastViewportSize == viewportSize) {
        _resetTransform();
      }
    });
  }

  void _resetTransform() {
    final Size? viewportSize = _lastViewportSize;
    if (viewportSize == null || viewportSize.isEmpty) {
      return;
    }
    _stopTransformAnimation();
    final double fitScale = _scaleFor(viewportSize, widget.fit);
    final double scale = _clampScale(
      widget.initialScale ?? fitScale,
      viewportSize,
    );
    final Offset offset = Offset(
      (viewportSize.width - widget.imageWidth * scale) / 2,
      (viewportSize.height - widget.imageHeight * scale) / 2,
    );
    _controller._transform.value = _matrixFor(
      scale,
      _clampOffset(scale, offset, viewportSize),
    );
  }

  void _zoomTo(double requestedScale, Offset? focalPoint) {
    final Size? viewportSize = _lastViewportSize;
    if (viewportSize == null || viewportSize.isEmpty) {
      return;
    }
    _stopTransformAnimation();
    final Offset focus =
        focalPoint ?? Offset(viewportSize.width / 2, viewportSize.height / 2);
    _controller._transform.value = _targetMatrixForScale(
      requestedScale,
      focus,
      viewportSize,
    );
    _scheduleSettle();
  }

  void _fitCurrentTransformToBounds() {
    final Size? viewportSize = _lastViewportSize;
    if (viewportSize == null || viewportSize.isEmpty) {
      return;
    }
    final Matrix4 clamped = _clampMatrix(
      _controller._transform.value,
      viewportSize,
    );
    if (!_matrixClose(_controller._transform.value, clamped)) {
      _controller._transform.value = clamped;
    }
  }

  Matrix4 _targetMatrixForScale(
    double requestedScale,
    Offset viewportFocus,
    Size viewportSize,
  ) {
    final double scale = _clampScale(requestedScale, viewportSize);
    final Matrix4 inverse = Matrix4.inverted(_controller._transform.value);
    final Offset sceneFocus = MatrixUtils.transformPoint(
      inverse,
      viewportFocus,
    );
    final Offset offset = viewportFocus - sceneFocus * scale;
    return _clampMatrix(_matrixFor(scale, offset), viewportSize);
  }

  Matrix4 _clampMatrix(Matrix4 matrix, Size viewportSize) {
    final double scale = _clampScale(
      pixaLargeImageTransformScale(matrix),
      viewportSize,
    );
    final Offset offset = _clampOffset(
      scale,
      Offset(matrix.storage[12], matrix.storage[13]),
      viewportSize,
    );
    return _matrixFor(scale, offset);
  }

  Matrix4 _matrixFor(double scale, Offset offset) {
    return Matrix4.identity()
      ..translateByDouble(offset.dx, offset.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  Offset _clampOffset(double scale, Offset offset, Size viewportSize) {
    return Offset(
      _clampAxis(offset.dx, viewportSize.width, widget.imageWidth * scale),
      _clampAxis(offset.dy, viewportSize.height, widget.imageHeight * scale),
    );
  }

  double _clampAxis(double value, double viewportExtent, double imageExtent) {
    if (imageExtent <= viewportExtent) {
      return (viewportExtent - imageExtent) / 2;
    }
    return value.clamp(viewportExtent - imageExtent, 0).toDouble();
  }

  double _clampScale(double scale, Size viewportSize) {
    return scale
        .clamp(_minScaleFor(viewportSize), _maxScaleFor(viewportSize))
        .toDouble();
  }

  double _minScaleFor(Size viewportSize) {
    return math.max(
      0.000001,
      widget.minScale ?? _scaleFor(viewportSize, widget.fit),
    );
  }

  double _maxScaleFor(Size viewportSize) {
    return math.max(widget.maxScale, _minScaleFor(viewportSize));
  }

  bool _matrixClose(Matrix4 a, Matrix4 b) {
    for (var i = 0; i < 16; i += 1) {
      if ((a.storage[i] - b.storage[i]).abs() > 0.0001) {
        return false;
      }
    }
    return true;
  }

  bool _nearlyEqual(double a, double b) {
    return (a - b).abs() <= 0.0001;
  }

  double _scaleFor(Size viewportSize, BoxFit fit) {
    final double widthScale = viewportSize.width / widget.imageWidth;
    final double heightScale = viewportSize.height / widget.imageHeight;
    return switch (fit) {
      BoxFit.cover => math.max(widthScale, heightScale),
      BoxFit.fill => widthScale,
      BoxFit.fitWidth => widthScale,
      BoxFit.fitHeight => heightScale,
      BoxFit.none => 1.0,
      _ => math.min(widthScale, heightScale),
    };
  }
}

final class _TileImage extends StatelessWidget {
  const _TileImage({
    super.key,
    required this.tile,
    required this.request,
    required this.filterQuality,
    required this.errorBuilder,
  });

  final PixaLargeImageTile tile;
  final PixaRequest request;
  final FilterQuality filterQuality;
  final PixaErrorBuilder? errorBuilder;

  @override
  Widget build(BuildContext context) {
    return Positioned.fromRect(
      rect: tile.sourceRect,
      child: PixaImage(
        request: request,
        fit: BoxFit.fill,
        filterQuality: filterQuality,
        placeholder: const PixaPlaceholder.color(Colors.transparent),
        errorBuilder: errorBuilder,
        transitionDuration: Duration.zero,
      ),
    );
  }
}
