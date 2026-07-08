import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';

import '../models/image_post.dart';
import '../pixa/pixa_recipes.dart';
import '../theme/neu_palette.dart';
import '../widgets/neu_controls.dart';
import 'display_previews.dart';

/// The Rust processor lab — cycles through every public helper.
class ProcessorLabPreview extends StatefulWidget {
  const ProcessorLabPreview({super.key, required this.post});

  final ImagePost post;

  @override
  State<ProcessorLabPreview> createState() => _ProcessorLabPreviewState();
}

class _ProcessorLabPreviewState extends State<ProcessorLabPreview> {
  late final List<ProcessorDemo> _demos = processorDemos();
  int _index = 0;

  void _next() => setState(() => _index = (_index + 1) % _demos.length);
  void _prev() =>
      setState(() => _index = (_index - 1 + _demos.length) % _demos.length);

  @override
  Widget build(BuildContext context) {
    final ProcessorDemo demo = _demos[_index];
    return ScenarioPreviewFrame(
      actions: <Widget>[
        ScenarioAction(
          label: 'Prev',
          icon: Icons.chevron_left_rounded,
          onPressed: _prev,
        ),
        ScenarioAction(
          label: 'Next',
          icon: Icons.chevron_right_rounded,
          onPressed: _next,
        ),
      ],
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          PixaImage(
            request: networkRequest(
              widget.post.imageUrl,
              targetWidth: 460,
              processors: demo.processors,
            ),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            semanticLabel: 'Processor lab: ${demo.label}',
            placeholder: learnPlaceholder(context),
            progressBuilder: pixaProgressBuilder,
            errorBuilder: pixaErrorBuilder,
            transitionDuration: kLearnTransitionDuration,
          ),
          Positioned(bottom: 8, left: 8, child: _DemoBadge(label: demo.label)),
        ],
      ),
    );
  }
}

class _DemoBadge extends StatelessWidget {
  const _DemoBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: palette.overlayScrim,
        shape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          label,
          style: TextStyle(
            color: palette.surface,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

/// Demonstrates the no-upscale thumbnail processor.
class ThumbnailPreview extends StatelessWidget {
  const ThumbnailPreview({super.key, required this.post});

  final ImagePost post;

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      child: PixaImage(
        request: networkRequest(
          post.imageUrl,
          processors: <String>[PixaProcessors.thumbnail(320, 240)],
        ),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        semanticLabel: 'Thumbnail processor demo',
        placeholder: learnPlaceholder(context),
        progressBuilder: pixaProgressBuilder,
        errorBuilder: pixaErrorBuilder,
        transitionDuration: kLearnTransitionDuration,
      ),
    );
  }
}

/// Demonstrates encoded header metadata probe without full decode.
class MetadataPreview extends StatefulWidget {
  const MetadataPreview({super.key, required this.post});

  final ImagePost post;

  @override
  State<MetadataPreview> createState() => _MetadataPreviewState();
}

class _MetadataPreviewState extends State<MetadataPreview> {
  PixaImageMetadata? _meta;
  int _bytes = 0;
  String? _error;
  bool _loading = false;

  Future<void> _probe() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final PixaPipelineLoad load = await Pixa.pipeline.load(
        PixaRequest.network(
          widget.post.imageUrl,
          cachePolicy: const PixaCachePolicy.cacheOnly(),
          priority: PixaPriority.high,
        ),
      );
      try {
        final PixaImageMetadata meta = PixaImageMetadata.parseEncoded(
          load.bytes,
        );
        setState(() {
          _meta = meta;
          _bytes = load.bytes.length;
        });
      } finally {
        load.dispose();
      }
    } on Object catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return ScenarioPreviewFrame(
      height: 180,
      actions: <Widget>[
        ScenarioAction(
          label: 'Probe metadata',
          icon: Icons.science_outlined,
          onPressed: _loading ? null : _probe,
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _meta == null
            ? Center(
                child: _loading
                    ? const NeuSpinner(size: 22)
                    : Text(
                        _error ?? 'Tap probe to read the encoded header',
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 13,
                        ),
                      ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _MetaLine('format', _meta!.format.name.toUpperCase()),
                  _MetaLine('dimensions', '${_meta!.width}×${_meta!.height}'),
                  _MetaLine('animated', _meta!.isAnimated ? 'yes' : 'no'),
                  _MetaLine('progressive', _meta!.isProgressive ? 'yes' : 'no'),
                  _MetaLine('encoded', formatBytes(_bytes)),
                ],
              ),
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                color: context.neu.textMuted,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: context.neu.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Demonstrates the tiled large-image viewer inline.
class LargeImageInlinePreview extends StatelessWidget {
  const LargeImageInlinePreview({super.key, required this.post});

  final ImagePost post;

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      height: 240,
      child: PixaLargeImage(
        request: postRequest(post, targetPixels: 512),
        imageWidth: post.width > 0 ? post.width : 1024,
        imageHeight: post.height > 0 ? post.height : 1024,
        tileMode: PixaLargeImageTileMode.adaptive,
        backgroundColor: context.neu.base,
        fit: BoxFit.cover,
        placeholder: learnPlaceholder(context),
        tileErrorBuilder: pixaTileErrorBuilder,
      ),
    );
  }
}

/// Demonstrates streaming progressive JPEG preview.
class ProgressiveJpegPreview extends StatelessWidget {
  const ProgressiveJpegPreview({super.key});

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      child: PixaImage(
        request: networkRequest(
          'https://raw.githubusercontent.com/sindresorhus/awesome/main/media/progressive.jpg',
          targetWidth: 480,
        ),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        semanticLabel: 'Progressive JPEG streaming preview demo',
        placeholder: learnPlaceholder(context),
        progressBuilder: pixaProgressBuilder,
        errorBuilder: pixaErrorBuilder,
        transitionDuration: kLearnTransitionDuration,
      ),
    );
  }
}

/// Demonstrates animated GIF playback control.
class AnimatedGifPreview extends StatefulWidget {
  const AnimatedGifPreview({super.key, required this.url});

  final String url;

  @override
  State<AnimatedGifPreview> createState() => _AnimatedGifPreviewState();
}

class _AnimatedGifPreviewState extends State<AnimatedGifPreview> {
  final PixaAnimationController _controller = PixaAnimationController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      actions: <Widget>[
        ScenarioAction(
          label: 'Play',
          icon: Icons.play_arrow_rounded,
          selected: _controller.state == PixaAnimationPlaybackState.playing,
          onPressed: _controller.play,
        ),
        ScenarioAction(
          label: 'Pause',
          icon: Icons.pause_rounded,
          onPressed: _controller.pause,
        ),
        ScenarioAction(
          label: 'Stop',
          icon: Icons.stop_rounded,
          onPressed: _controller.stop,
        ),
      ],
      child: PixaImage(
        request: networkRequest(widget.url, targetWidth: 480),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        animationController: _controller,
        semanticLabel: 'Animated GIF playback demo',
        placeholder: learnPlaceholder(context),
        progressBuilder: pixaProgressBuilder,
        errorBuilder: pixaErrorBuilder,
        transitionDuration: kLearnTransitionDuration,
      ),
    );
  }
}

/// Demonstrates animated WebP (engine-backed animation path).
class AnimatedWebpPreview extends StatelessWidget {
  const AnimatedWebpPreview({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      child: PixaImage(
        request: networkRequest(url, targetWidth: 480),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        semanticLabel: 'Animated WebP playback demo',
        placeholder: learnPlaceholder(context),
        progressBuilder: pixaProgressBuilder,
        errorBuilder: pixaErrorBuilder,
        transitionDuration: kLearnTransitionDuration,
      ),
    );
  }
}

/// Demonstrates the retry surface on a deliberately failing host.
class RetryPreview extends StatelessWidget {
  const RetryPreview({super.key});

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      child: PixaImage.network(
        'https://images.example.invalid/missing.jpg',
        fit: BoxFit.cover,
        gaplessPlayback: true,
        semanticLabel: 'Retry and error recovery demo (deliberately failing)',
        placeholder: learnPlaceholder(context),
        errorBuilder: pixaErrorBuilder,
        retryPolicy: const PixaRetryPolicy.exponential(maxAttempts: 2),
        transitionDuration: kLearnTransitionDuration,
      ),
    );
  }
}

/// Detects whether a video-frame backend is available in this binary.
bool hasVideoFrameBackend() {
  final PixaDebugSnapshot snapshot = PixaDebugInspector.snapshot();
  final bool native =
      snapshot.registryArchitecture.videoFrameBackends > 0 &&
      snapshot.registryArchitecture.videoFrameEncodedOutputBackends > 0;
  final bool mjpeg = snapshot
      .capabilities
      .runtimePluginRegistryStats
      .videoFrameSourceKinds
      .isNotEmpty;
  return native || mjpeg;
}

/// Demonstrates the video-frame source when a backend is available.
class VideoFramePreview extends StatelessWidget {
  const VideoFramePreview({super.key});

  @override
  Widget build(BuildContext context) {
    final bool available = hasVideoFrameBackend();
    return ScenarioPreviewFrame(
      child: available
          ? PixaImage.videoFrame(
              'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
              timestamp: const Duration(seconds: 1),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              semanticLabel: 'Video frame capture demo',
              placeholder: learnPlaceholder(context),
              errorBuilder: pixaErrorBuilder,
              transitionDuration: kLearnTransitionDuration,
            )
          : _Unavailable(
              icon: Icons.video_file_outlined,
              label: 'video-frame backend unavailable in this build',
            ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, color: palette.textMuted, size: 32),
            const SizedBox(height: 10),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
