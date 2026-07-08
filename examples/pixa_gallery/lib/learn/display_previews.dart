import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';

import '../models/image_post.dart';
import '../pixa/pixa_recipes.dart';
import '../theme/neu_palette.dart';
import '../widgets/neu_controls.dart';
import '../widgets/neu_surface.dart';

/// The raised frame every scenario preview lives inside.
class ScenarioPreviewFrame extends StatelessWidget {
  const ScenarioPreviewFrame({
    super.key,
    required this.child,
    this.height = 200,
    this.actions = const <Widget>[],
  });

  final Widget child;
  final double height;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        NeuSurface(
          shape: NeuShape.concave,
          elevation: NeuElevation.low,
          borderRadius: BorderRadius.circular(16),
          padding: EdgeInsets.zero,
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: child,
            ),
          ),
        ),
        if (actions.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          ScenarioControlBar(children: actions),
        ],
      ],
    );
  }
}

/// A wrapped row of compact controls, for preview action bars.
class ScenarioControlBar extends StatelessWidget {
  const ScenarioControlBar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 8, children: children);
  }
}

/// Small neumorphic action button used in preview control bars.
class ScenarioAction extends StatelessWidget {
  const ScenarioAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.selected = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return NeuButton(
      onPressed: onPressed,
      accent: selected,
      icon: icon == null ? null : Icon(icon!, size: 18),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      borderRadius: BorderRadius.circular(14),
      child: Text(label),
    );
  }
}

/// Displays the [PixaImage] widget surface with fit / progress.
class DisplayWidgetPreview extends StatelessWidget {
  const DisplayWidgetPreview({super.key, required this.post});

  final ImagePost post;

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      child: PixaImage(
        request: postRequest(post, targetPixels: 480),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        semanticLabel: 'PixaImage widget demo',
        placeholder: learnPlaceholder(context),
        progressBuilder: pixaProgressBuilder,
        errorBuilder: pixaErrorBuilder,
        transitionDuration: kLearnTransitionDuration,
      ),
    );
  }
}

/// Demonstrates [PixaProvider] as a Flutter [ImageProvider].
class DisplayProviderPreview extends StatelessWidget {
  const DisplayProviderPreview({super.key, required this.post});

  final ImagePost post;

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      child: Image(
        image: PixaProvider.network(post.imageUrl, targetWidth: 480),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        semanticLabel: 'PixaProvider ImageProvider compatibility demo',
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) {
          return pixaErrorBuilder(
            context,
            PixaFailure(
              requestId: -1,
              stage: PixaStage.fetch,
              safeMessage: error.toString(),
              retryability: PixaRetryability.retryable,
              originalError: error,
              stackTrace: stack,
            ),
            () {},
          );
        },
      ),
    );
  }
}

/// Demonstrates [PixaController] reload / cancel / pause / resume.
class DisplayControllerPreview extends StatefulWidget {
  const DisplayControllerPreview({super.key, required this.post});

  final ImagePost post;

  @override
  State<DisplayControllerPreview> createState() =>
      _DisplayControllerPreviewState();
}

class _DisplayControllerPreviewState extends State<DisplayControllerPreview> {
  final PixaController _controller = PixaController();
  String _stateLabel = 'idle';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onState);
  }

  @override
  void dispose() {
    _controller.removeListener(_onState);
    _controller.dispose();
    super.dispose();
  }

  void _onState() {
    // PixaController.attach can fire this listener synchronously during the
    // first build (the embedded PixaImage attaches in initState), so defer
    // the setState to a safe frame instead of mutating the build mid-flight.
    final PixaLoadState s = _controller.state;
    final String label = switch (s) {
      PixaIdle() => 'idle',
      PixaLoading() => 'loading',
      PixaCompleted() => 'completed',
      PixaFailed() => 'failed',
      PixaCancelled() => 'cancelled',
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _stateLabel != label) {
        setState(() => _stateLabel = label);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      actions: <Widget>[
        ScenarioAction(
          label: 'Reload',
          icon: Icons.refresh_rounded,
          onPressed: _controller.reload,
        ),
        ScenarioAction(
          label: 'Cancel',
          icon: Icons.cancel_outlined,
          onPressed: _controller.cancel,
        ),
        ScenarioAction(
          label: 'Pause',
          icon: Icons.pause_rounded,
          onPressed: _controller.pause,
        ),
        ScenarioAction(
          label: 'Resume',
          icon: Icons.play_arrow_rounded,
          onPressed: _controller.resume,
        ),
      ],
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          PixaImage(
            request: postRequest(widget.post, targetPixels: 440),
            controller: _controller,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            semanticLabel: 'PixaController reload and cancel demo',
            placeholder: learnPlaceholder(context),
            progressBuilder: pixaProgressBuilder,
            errorBuilder: pixaErrorBuilder,
            transitionDuration: kLearnTransitionDuration,
          ),
          Positioned(top: 8, left: 8, child: _StateChip(label: _stateLabel)),
        ],
      ),
    );
  }
}

/// Demonstrates low-level [Pixa.pipeline.load] returning raw bytes + metadata.
class DisplayPipelinePreview extends StatefulWidget {
  const DisplayPipelinePreview({super.key, required this.post});

  final ImagePost post;

  @override
  State<DisplayPipelinePreview> createState() => _DisplayPipelinePreviewState();
}

class _DisplayPipelinePreviewState extends State<DisplayPipelinePreview> {
  PixaPipelineLoad? _load;
  bool _loading = false;
  String _summary = 'Tap load to fetch bytes via Pixa.pipeline.load';

  @override
  void dispose() {
    _load?.dispose();
    super.dispose();
  }

  Future<void> _loadBytes() async {
    setState(() => _loading = true);
    _load?.dispose();
    _load = await Pixa.pipeline.load(
      PixaRequest.network(
        widget.post.imageUrl,
        cachePolicy: const PixaCachePolicy.noStore(),
        priority: PixaPriority.high,
      ),
    );
    final PixaImageMetadata meta = PixaImageMetadata.parseEncoded(_load!.bytes);
    setState(() {
      _loading = false;
      _summary =
          '${formatBytes(_load!.bytes.length)} · '
          '${meta.format.name.toUpperCase()} · '
          '${meta.width}×${meta.height}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      height: 130,
      actions: <Widget>[
        ScenarioAction(
          label: 'Load bytes',
          icon: Icons.download_rounded,
          onPressed: _loading ? null : _loadBytes,
        ),
      ],
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              Icon(Icons.memory_rounded, color: context.neu.accent, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Pipeline bytes',
                      style: TextStyle(
                        color: context.neu.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _summary,
                      style: TextStyle(
                        color: context.neu.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (_loading) const NeuSpinner(size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return NeuSurface(
      shape: NeuShape.convex,
      elevation: NeuElevation.low,
      borderRadius: BorderRadius.circular(12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Text(
        label,
        style: TextStyle(
          color: palette.accent,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}
