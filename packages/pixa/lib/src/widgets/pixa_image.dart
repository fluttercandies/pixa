import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../animation.dart';
import '../controller.dart';
import '../failure.dart';
import '../provider.dart';
import '../progress.dart';
import '../request.dart';
import '../source.dart';

/// Builds an error UI with a retry callback.
typedef PixaErrorBuilder = Widget Function(
    BuildContext context, PixaFailure failure, VoidCallback retry);

/// Builds a loading UI with the latest progress event.
typedef PixaProgressBuilder = Widget Function(
    BuildContext context, PixaProgress? progress);

/// Placeholder descriptor.
@immutable
final class PixaPlaceholder {
  /// Solid color placeholder.
  const PixaPlaceholder.color(this.color) : widget = null;

  /// Widget placeholder.
  const PixaPlaceholder.widget(this.widget) : color = null;

  /// Placeholder color.
  final Color? color;

  /// Placeholder widget.
  final Widget? widget;

  /// Builds the placeholder widget.
  Widget build(BuildContext context) {
    final Widget? widget = this.widget;
    if (widget != null) {
      return widget;
    }
    return ColoredBox(color: color ?? Colors.transparent);
  }
}

/// Flutter image widget backed by the Rust Pixa pipeline.
final class PixaImage extends StatefulWidget {
  /// Creates a Pixa image from a request.
  const PixaImage({
    super.key,
    required this.request,
    this.controller,
    this.animationController,
    this.animationOptions = const PixaAnimationOptions(),
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.semanticLabel,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.medium,
    this.placeholder,
    this.progressBuilder,
    this.errorBuilder,
    this.transitionDuration = Duration.zero,
    this.overlay,
    this.background,
    this.focusPoint,
    this.circle = false,
    this.borderRadius,
    this.pressOverlay,
    this.tapToRetry = true,
  });

  /// Creates a network image.
  factory PixaImage.network(
    String url, {
    Key? key,
    double? width,
    double? height,
    BoxFit? fit,
    AlignmentGeometry alignment = Alignment.center,
    String? semanticLabel,
    bool gaplessPlayback = false,
    FilterQuality filterQuality = FilterQuality.medium,
    PixaController? controller,
    PixaAnimationController? animationController,
    PixaAnimationOptions animationOptions = const PixaAnimationOptions(),
    PixaPlaceholder? placeholder,
    PixaProgressBuilder? progressBuilder,
    PixaErrorBuilder? errorBuilder,
    Duration transitionDuration = Duration.zero,
    BorderRadius? borderRadius,
    bool circle = false,
    Widget? overlay,
    Widget? background,
    AlignmentGeometry? focusPoint,
    Widget? pressOverlay,
    bool tapToRetry = true,
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaRedirectPolicy redirectPolicy = const PixaRedirectPolicy(),
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    Map<String, String> headers = const <String, String>{},
    PixaRequest? lowRes,
  }) {
    return PixaImage(
      key: key,
      request: PixaRequest(
        source: PixaSource.network(Uri.parse(url)),
        headers: headers,
        targetSize: PixaTargetSize(
          width: width?.round(),
          height: height?.round(),
        ),
        fit: fit,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        redirectPolicy: redirectPolicy,
        pluginExecutionPolicy: pluginExecutionPolicy,
        lowRes: lowRes,
      ),
      controller: controller,
      animationController: animationController,
      animationOptions: animationOptions,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      semanticLabel: semanticLabel,
      gaplessPlayback: gaplessPlayback,
      filterQuality: filterQuality,
      placeholder: placeholder,
      progressBuilder: progressBuilder,
      errorBuilder: errorBuilder,
      transitionDuration: transitionDuration,
      borderRadius: borderRadius,
      circle: circle,
      overlay: overlay,
      background: background,
      focusPoint: focusPoint,
      pressOverlay: pressOverlay,
      tapToRetry: tapToRetry,
    );
  }

  /// Creates a file image.
  factory PixaImage.file(
    String path, {
    Key? key,
    double? width,
    double? height,
    BoxFit? fit,
    AlignmentGeometry alignment = Alignment.center,
    String? semanticLabel,
    bool gaplessPlayback = false,
    FilterQuality filterQuality = FilterQuality.medium,
    PixaController? controller,
    PixaAnimationController? animationController,
    PixaAnimationOptions animationOptions = const PixaAnimationOptions(),
    PixaPlaceholder? placeholder,
    PixaProgressBuilder? progressBuilder,
    PixaErrorBuilder? errorBuilder,
    Duration transitionDuration = Duration.zero,
    BorderRadius? borderRadius,
    bool circle = false,
    Widget? overlay,
    Widget? background,
    AlignmentGeometry? focusPoint,
    Widget? pressOverlay,
    bool tapToRetry = true,
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    PixaRequest? lowRes,
    bool exifThumbnailFirst = true,
  }) {
    return PixaImage(
      key: key,
      request: PixaRequest.file(
        path,
        targetSize:
            PixaTargetSize(width: width?.round(), height: height?.round()),
        fit: fit,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        pluginExecutionPolicy: pluginExecutionPolicy,
        lowRes: lowRes,
        exifThumbnailFirst: exifThumbnailFirst,
      ),
      controller: controller,
      animationController: animationController,
      animationOptions: animationOptions,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      semanticLabel: semanticLabel,
      gaplessPlayback: gaplessPlayback,
      filterQuality: filterQuality,
      placeholder: placeholder,
      progressBuilder: progressBuilder,
      errorBuilder: errorBuilder,
      transitionDuration: transitionDuration,
      borderRadius: borderRadius,
      circle: circle,
      overlay: overlay,
      background: background,
      focusPoint: focusPoint,
      pressOverlay: pressOverlay,
      tapToRetry: tapToRetry,
    );
  }

  /// Creates an asset image.
  factory PixaImage.asset(
    String name, {
    Key? key,
    String? package,
    double? width,
    double? height,
    BoxFit? fit,
    AlignmentGeometry alignment = Alignment.center,
    String? semanticLabel,
    bool gaplessPlayback = false,
    FilterQuality filterQuality = FilterQuality.medium,
    PixaController? controller,
    PixaAnimationController? animationController,
    PixaAnimationOptions animationOptions = const PixaAnimationOptions(),
    PixaPlaceholder? placeholder,
    PixaProgressBuilder? progressBuilder,
    PixaErrorBuilder? errorBuilder,
    Duration transitionDuration = Duration.zero,
    BorderRadius? borderRadius,
    bool circle = false,
    Widget? overlay,
    Widget? background,
    AlignmentGeometry? focusPoint,
    Widget? pressOverlay,
    bool tapToRetry = true,
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    PixaRequest? lowRes,
  }) {
    return PixaImage(
      key: key,
      request: PixaRequest(
        source: PixaSource.asset(name, package: package),
        targetSize:
            PixaTargetSize(width: width?.round(), height: height?.round()),
        fit: fit,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        pluginExecutionPolicy: pluginExecutionPolicy,
        lowRes: lowRes,
      ),
      controller: controller,
      animationController: animationController,
      animationOptions: animationOptions,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      semanticLabel: semanticLabel,
      gaplessPlayback: gaplessPlayback,
      filterQuality: filterQuality,
      placeholder: placeholder,
      progressBuilder: progressBuilder,
      errorBuilder: errorBuilder,
      transitionDuration: transitionDuration,
      borderRadius: borderRadius,
      circle: circle,
      overlay: overlay,
      background: background,
      focusPoint: focusPoint,
      pressOverlay: pressOverlay,
      tapToRetry: tapToRetry,
    );
  }

  /// Creates a memory image.
  factory PixaImage.memory(
    String id,
    Uint8List bytes, {
    Key? key,
    double? width,
    double? height,
    BoxFit? fit,
    AlignmentGeometry alignment = Alignment.center,
    String? semanticLabel,
    bool gaplessPlayback = false,
    FilterQuality filterQuality = FilterQuality.medium,
    PixaController? controller,
    PixaAnimationController? animationController,
    PixaAnimationOptions animationOptions = const PixaAnimationOptions(),
    PixaPlaceholder? placeholder,
    PixaProgressBuilder? progressBuilder,
    PixaErrorBuilder? errorBuilder,
    Duration transitionDuration = Duration.zero,
    BorderRadius? borderRadius,
    bool circle = false,
    Widget? overlay,
    Widget? background,
    AlignmentGeometry? focusPoint,
    Widget? pressOverlay,
    bool tapToRetry = true,
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    PixaRequest? lowRes,
  }) {
    return PixaImage(
      key: key,
      request: PixaRequest(
        source: PixaSource.memory(id, bytes),
        targetSize:
            PixaTargetSize(width: width?.round(), height: height?.round()),
        fit: fit,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        pluginExecutionPolicy: pluginExecutionPolicy,
        lowRes: lowRes,
      ),
      controller: controller,
      animationController: animationController,
      animationOptions: animationOptions,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      semanticLabel: semanticLabel,
      gaplessPlayback: gaplessPlayback,
      filterQuality: filterQuality,
      placeholder: placeholder,
      progressBuilder: progressBuilder,
      errorBuilder: errorBuilder,
      transitionDuration: transitionDuration,
      borderRadius: borderRadius,
      circle: circle,
      overlay: overlay,
      background: background,
      focusPoint: focusPoint,
      pressOverlay: pressOverlay,
      tapToRetry: tapToRetry,
    );
  }

  /// Creates a bytes image.
  factory PixaImage.bytes(
    Uint8List bytes, {
    Key? key,
    String? id,
    double? width,
    double? height,
    BoxFit? fit,
    AlignmentGeometry alignment = Alignment.center,
    String? semanticLabel,
    bool gaplessPlayback = false,
    FilterQuality filterQuality = FilterQuality.medium,
    PixaController? controller,
    PixaAnimationController? animationController,
    PixaAnimationOptions animationOptions = const PixaAnimationOptions(),
    PixaPlaceholder? placeholder,
    PixaProgressBuilder? progressBuilder,
    PixaErrorBuilder? errorBuilder,
    Duration transitionDuration = Duration.zero,
    BorderRadius? borderRadius,
    bool circle = false,
    Widget? overlay,
    Widget? background,
    AlignmentGeometry? focusPoint,
    Widget? pressOverlay,
    bool tapToRetry = true,
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    PixaRequest? lowRes,
  }) {
    return PixaImage(
      key: key,
      request: PixaRequest(
        source: PixaSource.bytes(bytes, id: id),
        targetSize:
            PixaTargetSize(width: width?.round(), height: height?.round()),
        fit: fit,
        cachePolicy: cachePolicy,
        priority: priority,
        retryPolicy: retryPolicy,
        pluginExecutionPolicy: pluginExecutionPolicy,
        lowRes: lowRes,
      ),
      controller: controller,
      animationController: animationController,
      animationOptions: animationOptions,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      semanticLabel: semanticLabel,
      gaplessPlayback: gaplessPlayback,
      filterQuality: filterQuality,
      placeholder: placeholder,
      progressBuilder: progressBuilder,
      errorBuilder: errorBuilder,
      transitionDuration: transitionDuration,
      borderRadius: borderRadius,
      circle: circle,
      overlay: overlay,
      background: background,
      focusPoint: focusPoint,
      pressOverlay: pressOverlay,
      tapToRetry: tapToRetry,
    );
  }

  /// runtime request.
  final PixaRequest request;

  /// Optional lifecycle controller.
  final PixaController? controller;

  /// Optional animated image playback controller.
  final PixaAnimationController? animationController;

  /// Animated image playback options.
  final PixaAnimationOptions animationOptions;

  /// Width.
  final double? width;

  /// Height.
  final double? height;

  /// Fit.
  final BoxFit? fit;

  /// Alignment.
  final AlignmentGeometry alignment;

  /// Semantics label.
  final String? semanticLabel;

  /// Gapless playback.
  final bool gaplessPlayback;

  /// Filter quality.
  final FilterQuality filterQuality;

  /// Placeholder.
  final PixaPlaceholder? placeholder;

  /// Loading progress builder.
  final PixaProgressBuilder? progressBuilder;

  /// Error builder.
  final PixaErrorBuilder? errorBuilder;

  /// Fade-in duration.
  final Duration transitionDuration;

  /// Optional foreground overlay.
  final Widget? overlay;

  /// Optional background.
  final Widget? background;

  /// Optional focus point.
  final AlignmentGeometry? focusPoint;

  /// Whether to clip as circle.
  final bool circle;

  /// Optional border radius.
  final BorderRadius? borderRadius;

  /// Optional overlay shown while pressed.
  final Widget? pressOverlay;

  /// Whether tapping an error retries.
  final bool tapToRetry;

  @override
  State<PixaImage> createState() => _PixaImageState();
}

final class _PixaImageState extends State<PixaImage> {
  late PixaController _controller;
  late PixaLoadState _lastObservedState;
  late int _lastObservedGeneration;
  ScrollPosition? _scrollPosition;
  PixaLoadState? _pendingControllerState;
  PixaController? _pendingControllerTarget;
  bool _ownsController = false;
  bool _pressed = false;
  bool _visibilityUpdateScheduled = false;
  bool _controllerStateUpdateScheduled = false;
  PixaProvider? _cachedProvider;
  PixaRequest? _cachedProviderRequest;
  PixaAnimationController? _cachedAnimationController;
  PixaAnimationOptions? _cachedAnimationOptions;
  int? _cachedProviderGeneration;
  bool? _cachedProviderNeedsProgress;

  @override
  void initState() {
    super.initState();
    _attachController(widget.controller);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncVisibilityTracking();
  }

  @override
  void didUpdateWidget(PixaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _pendingControllerState = null;
      _pendingControllerTarget = null;
      _detachController();
      _attachController(widget.controller);
    }
    _syncVisibilityTracking();
  }

  @override
  void dispose() {
    _unbindScrollPosition();
    _pendingControllerState = null;
    _pendingControllerTarget = null;
    _detachController();
    super.dispose();
  }

  @override
  void reassemble() {
    super.reassemble();
    _pressed = false;
    _controller.reassemble();
  }

  @override
  Widget build(BuildContext context) {
    final PixaRequest? request = _requestWithoutLayout(context);
    if (request != null) {
      return _buildImage(context, request);
    }
    return LayoutBuilder(builder: _buildWithConstraints);
  }

  Widget _buildWithConstraints(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    final PixaRequest request = _effectiveRequestForLayout(
      context,
      constraints,
    );
    return _buildImage(context, request);
  }

  Widget _buildImage(BuildContext context, PixaRequest request) {
    final PixaProvider provider = _providerFor(request);
    Widget image = Image(
      image: provider,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.focusPoint ?? widget.alignment,
      semanticLabel: widget.semanticLabel,
      gaplessPlayback: widget.gaplessPlayback,
      filterQuality: widget.filterQuality,
      frameBuilder: (BuildContext context, Widget child, int? frame,
          bool wasSynchronouslyLoaded) {
        return _frameBuilder(
          context,
          child,
          frame,
          wasSynchronouslyLoaded,
          request,
        );
      },
      errorBuilder: _errorBuilder,
    );

    if (widget.background != null ||
        widget.overlay != null ||
        _pressed && widget.pressOverlay != null) {
      image = Stack(
        fit: StackFit.passthrough,
        children: <Widget>[
          if (widget.background != null)
            Positioned.fill(child: widget.background!),
          image,
          if (widget.overlay != null) Positioned.fill(child: widget.overlay!),
          if (_pressed && widget.pressOverlay != null)
            Positioned.fill(child: widget.pressOverlay!),
        ],
      );
    }

    if (widget.circle) {
      image = ClipOval(child: image);
    } else if (widget.borderRadius != null) {
      image = ClipRRect(borderRadius: widget.borderRadius!, child: image);
    }

    if (widget.pressOverlay == null &&
        (!widget.tapToRetry || _controller.state is! PixaFailed)) {
      return image;
    }

    return GestureDetector(
      onTap: widget.tapToRetry && _controller.state is PixaFailed
          ? _controller.retry
          : null,
      onTapDown: widget.pressOverlay == null
          ? null
          : (_) => setState(() => _pressed = true),
      onTapUp: widget.pressOverlay == null
          ? null
          : (_) => setState(() => _pressed = false),
      onTapCancel: widget.pressOverlay == null
          ? null
          : () => setState(() => _pressed = false),
      child: image,
    );
  }

  PixaProvider _providerFor(PixaRequest request) {
    final bool needsProgress = _needsProgressCallback;
    final int generation = _controller.generation;
    final PixaAnimationController? animationController =
        widget.animationController;
    final PixaAnimationOptions animationOptions = widget.animationOptions;
    final PixaProvider? cached = _cachedProvider;
    if (cached != null &&
        identical(_cachedProviderRequest, request) &&
        _cachedProviderGeneration == generation &&
        _cachedProviderNeedsProgress == needsProgress &&
        identical(_cachedAnimationController, animationController) &&
        _cachedAnimationOptions == animationOptions) {
      return cached;
    }
    final PixaProvider provider = PixaProvider(
      request: request,
      generation: generation,
      onProgress: needsProgress ? _handleProgress : null,
      animationController: animationController,
      animationOptions: animationOptions,
    );
    _cachedProvider = provider;
    _cachedProviderRequest = request;
    _cachedProviderGeneration = generation;
    _cachedProviderNeedsProgress = needsProgress;
    _cachedAnimationController = animationController;
    _cachedAnimationOptions = animationOptions;
    return provider;
  }

  Widget _frameBuilder(
    BuildContext context,
    Widget child,
    int? frame,
    bool wasSynchronouslyLoaded,
    PixaRequest request,
  ) {
    if (frame == null) {
      if (_publishesLoadState && _controller.state is! PixaLoading) {
        _setControllerState(const PixaLoading());
      }
      final PixaProgress? progress = switch (_controller.state) {
        PixaLoading(:final progress) => progress,
        _ => null,
      };
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: widget.progressBuilder?.call(context, progress) ??
            _progressivePreviewImage(progress) ??
            _lowResImage(context, request) ??
            widget.placeholder?.build(context) ??
            const SizedBox.expand(),
      );
    }
    if (!_ownsController) {
      _setControllerState(const PixaCompleted());
    }
    if (wasSynchronouslyLoaded || widget.transitionDuration == Duration.zero) {
      return child;
    }
    return AnimatedOpacity(
      opacity: 1,
      duration: widget.transitionDuration,
      child: child,
    );
  }

  Widget _errorBuilder(
      BuildContext context, Object error, StackTrace? stackTrace) {
    final PixaFailure failure = error is PixaFailure
        ? error
        : PixaFailure(
            requestId: -1,
            stage: PixaStage.decode,
            safeMessage: error.toString(),
            retryability: PixaRetryability.unknown,
            originalError: error,
            stackTrace: stackTrace,
          );
    if (_publishesFailureState) {
      _setControllerState(PixaFailed(failure));
    }
    final PixaErrorBuilder? errorBuilder = widget.errorBuilder;
    if (errorBuilder != null) {
      return errorBuilder(context, failure, _controller.retry);
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: IconButton(
        icon: const Icon(Icons.refresh),
        onPressed: _controller.retry,
      ),
    );
  }

  PixaRequest? _requestWithoutLayout(BuildContext context) {
    final PixaTargetSize? widgetTarget = _widgetTargetSize(context);
    if (widgetTarget != null) {
      return _withAutomaticTarget(widget.request, widgetTarget);
    }
    final PixaTargetSize? requestTarget = widget.request.targetSize;
    if (requestTarget != null && !requestTarget.isEmpty) {
      return _withAutomaticTarget(widget.request, requestTarget);
    }
    return null;
  }

  PixaRequest _effectiveRequestForLayout(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    final PixaTargetSize? target = _layoutTargetSize(context, constraints);
    if (target == null) {
      return widget.request;
    }
    return _withAutomaticTarget(widget.request, target);
  }

  PixaRequest _withAutomaticTarget(PixaRequest request, PixaTargetSize target) {
    final PixaRequest? lowRes = request.lowRes;
    final PixaRequest? resolvedLowRes =
        lowRes == null ? null : _withAutomaticTarget(lowRes, target);
    if (!_shouldUseAutomaticTarget(request.targetSize, target) &&
        identical(resolvedLowRes, lowRes)) {
      return request;
    }
    return request.copyWith(
      targetSize: _shouldUseAutomaticTarget(request.targetSize, target)
          ? target
          : request.targetSize,
      lowRes: resolvedLowRes,
    );
  }

  bool _shouldUseAutomaticTarget(
    PixaTargetSize? current,
    PixaTargetSize target,
  ) {
    if (current == null || current.isEmpty) {
      return true;
    }
    final PixaTargetSize? logical = _logicalWidgetTarget();
    return logical != null &&
        current == logical &&
        (current.width != target.width || current.height != target.height);
  }

  PixaTargetSize? _logicalWidgetTarget() {
    if (widget.width == null && widget.height == null) {
      return null;
    }
    return PixaTargetSize(
      width: widget.width?.round(),
      height: widget.height?.round(),
    );
  }

  PixaTargetSize? _widgetTargetSize(BuildContext context) {
    final double? logicalWidth = _finitePositive(widget.width);
    final double? logicalHeight = _finitePositive(widget.height);
    if (logicalWidth == null && logicalHeight == null) {
      return null;
    }
    final double devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    return _targetSizeForLogicalSize(
      logicalWidth: logicalWidth,
      logicalHeight: logicalHeight,
      devicePixelRatio: devicePixelRatio,
    );
  }

  PixaTargetSize _targetSizeForLogicalSize({
    required double? logicalWidth,
    required double? logicalHeight,
    required double devicePixelRatio,
  }) {
    return PixaTargetSize(
      width: logicalWidth == null
          ? null
          : (logicalWidth * devicePixelRatio).round().clamp(1, 1 << 30).toInt(),
      height: logicalHeight == null
          ? null
          : (logicalHeight * devicePixelRatio)
              .round()
              .clamp(1, 1 << 30)
              .toInt(),
    );
  }

  PixaTargetSize? _layoutTargetSize(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    final double? logicalWidth =
        _finitePositive(widget.width) ?? _boundedMax(constraints.maxWidth);
    final double? logicalHeight =
        _finitePositive(widget.height) ?? _boundedMax(constraints.maxHeight);
    if (logicalWidth == null && logicalHeight == null) {
      return null;
    }
    final double devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    return _targetSizeForLogicalSize(
      logicalWidth: logicalWidth,
      logicalHeight: logicalHeight,
      devicePixelRatio: devicePixelRatio,
    );
  }

  double? _finitePositive(double? value) {
    return value != null && value.isFinite && value > 0 ? value : null;
  }

  double? _boundedMax(double value) {
    return value.isFinite && value > 0 ? value : null;
  }

  Widget? _lowResImage(BuildContext context, PixaRequest request) {
    final PixaRequest? lowRes = request.lowRes;
    if (lowRes == null) {
      return null;
    }
    return Image(
      image: PixaProvider(
        request: lowRes,
        generation: _controller.generation,
      ),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.focusPoint ?? widget.alignment,
      excludeFromSemantics: true,
      gaplessPlayback: true,
      filterQuality: widget.filterQuality,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) {
        return widget.placeholder?.build(context) ?? const SizedBox.expand();
      },
    );
  }

  Widget? _progressivePreviewImage(PixaProgress? progress) {
    final PixaProgressivePreview? preview = progress?.progressivePreview;
    if (preview == null) {
      return null;
    }
    return Image.memory(
      preview.bytes,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.focusPoint ?? widget.alignment,
      excludeFromSemantics: true,
      gaplessPlayback: true,
      filterQuality: widget.filterQuality,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) {
        return widget.placeholder?.build(context) ?? const SizedBox.expand();
      },
    );
  }

  void _attachController(PixaController? controller) {
    _ownsController = controller == null;
    _controller = controller ?? PixaController();
    _lastObservedState = _controller.state;
    _lastObservedGeneration = _controller.generation;
    _controller.addListener(_onControllerChanged);
    _controller.attach();
  }

  void _detachController() {
    _controller.removeListener(_onControllerChanged);
    _controller.detach();
    if (_ownsController) {
      _controller.dispose();
    }
  }

  void _onControllerChanged() {
    final PixaLoadState nextState = _controller.state;
    final int nextGeneration = _controller.generation;
    final bool affectsBuild = nextGeneration != _lastObservedGeneration ||
        !_isSameLoadState(_lastObservedState, nextState);
    _lastObservedState = nextState;
    _lastObservedGeneration = nextGeneration;
    if (affectsBuild && mounted) {
      setState(() {});
    }
  }

  void _setControllerState(PixaLoadState state) {
    final PixaLoadState? pendingState = _pendingControllerState;
    if (_isSameLoadState(pendingState ?? _controller.state, state)) {
      return;
    }
    _pendingControllerState = state;
    _pendingControllerTarget = _controller;
    if (_controllerStateUpdateScheduled) {
      return;
    }
    _controllerStateUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controllerStateUpdateScheduled = false;
      final PixaLoadState? next = _pendingControllerState;
      final PixaController? target = _pendingControllerTarget;
      _pendingControllerState = null;
      _pendingControllerTarget = null;
      if (mounted &&
          next != null &&
          target != null &&
          identical(target, _controller)) {
        target.setState(next);
      }
    });
  }

  void _handleProgress(PixaProgress progress) {
    if (!_publishesProgress(progress)) {
      return;
    }
    _setControllerState(PixaLoading(progress: progress));
  }

  bool get _needsProgressCallback =>
      !_ownsController || widget.progressBuilder != null;

  bool get _publishesLoadState =>
      !_ownsController || widget.progressBuilder != null;

  bool get _publishesFailureState =>
      !_ownsController || widget.tapToRetry || widget.pressOverlay != null;

  bool _publishesProgress(PixaProgress progress) {
    return !_ownsController ||
        widget.progressBuilder != null ||
        progress.progressivePreview != null;
  }

  void _syncVisibilityTracking() {
    if (_ownsController) {
      _unbindScrollPosition();
      return;
    }
    _bindScrollPosition();
    _scheduleVisibilityUpdate();
  }

  void _unbindScrollPosition() {
    _scrollPosition?.removeListener(_scheduleVisibilityUpdate);
    _scrollPosition = null;
  }

  void _bindScrollPosition() {
    final ScrollPosition? next = Scrollable.maybeOf(context)?.position;
    if (identical(_scrollPosition, next)) {
      return;
    }
    _scrollPosition?.removeListener(_scheduleVisibilityUpdate);
    _scrollPosition = next;
    _scrollPosition?.addListener(_scheduleVisibilityUpdate);
  }

  void _scheduleVisibilityUpdate() {
    if (_visibilityUpdateScheduled) {
      return;
    }
    _visibilityUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityUpdateScheduled = false;
      if (!mounted) {
        return;
      }
      if (_isVisibleInViewport()) {
        _controller.visible();
      } else {
        _controller.invisible();
      }
    });
  }

  bool _isVisibleInViewport() {
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize ||
        renderObject.size.isEmpty) {
      return true;
    }
    final Rect imageRect =
        renderObject.localToGlobal(Offset.zero) & renderObject.size;
    if (imageRect.isEmpty) {
      return false;
    }

    final BuildContext? scrollContext = Scrollable.maybeOf(context)?.context;
    final RenderObject? viewportObject = scrollContext?.findRenderObject();
    if (viewportObject is! RenderBox ||
        !viewportObject.attached ||
        !viewportObject.hasSize ||
        viewportObject.size.isEmpty) {
      return true;
    }
    final Rect viewportRect =
        viewportObject.localToGlobal(Offset.zero) & viewportObject.size;
    return imageRect.overlaps(viewportRect);
  }
}

bool _isSameLoadState(PixaLoadState previous, PixaLoadState next) {
  if (previous.runtimeType != next.runtimeType) {
    return false;
  }
  return switch ((previous, next)) {
    (PixaLoading(progress: final a), PixaLoading(progress: final b)) =>
      _isSameProgress(a, b),
    _ => true,
  };
}

bool _isSameProgress(PixaProgress? previous, PixaProgress? next) {
  if (identical(previous, next)) {
    return true;
  }
  if (previous == null || next == null) {
    return false;
  }
  return previous.requestId == next.requestId &&
      previous.stage == next.stage &&
      previous.receivedBytes == next.receivedBytes &&
      previous.expectedBytes == next.expectedBytes &&
      previous.message == next.message &&
      _isSameProgressivePreview(
        previous.progressivePreview,
        next.progressivePreview,
      );
}

bool _isSameProgressivePreview(
  PixaProgressivePreview? previous,
  PixaProgressivePreview? next,
) {
  if (identical(previous, next)) {
    return true;
  }
  if (previous == null || next == null) {
    return false;
  }
  return previous.sequence == next.sequence &&
      previous.mimeType == next.mimeType &&
      identical(previous.bytes, next.bytes);
}
