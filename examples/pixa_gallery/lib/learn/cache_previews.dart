import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';

import '../models/image_post.dart';
import '../pixa/pixa_recipes.dart';
import '../theme/neu_palette.dart';
import 'display_previews.dart';

/// Demonstrates all PixaSource variants (network / file / asset / memory /
/// bytes / custom) as a single mini grid.
class SourceBundlePreview extends StatefulWidget {
  const SourceBundlePreview({super.key, required this.post});

  final ImagePost post;

  @override
  State<SourceBundlePreview> createState() => _SourceBundlePreviewState();
}

class _SourceBundlePreviewState extends State<SourceBundlePreview> {
  String _selected = 'network';

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      height: 220,
      actions: <Widget>[
        for (final String source in const <String>[
          'network',
          'asset',
          'memory',
          'bytes',
        ])
          ScenarioAction(
            label: source,
            selected: _selected == source,
            onPressed: () => setState(() => _selected = source),
          ),
      ],
      child: _buildSelected(context),
    );
  }

  Widget _buildSelected(BuildContext context) {
    switch (_selected) {
      case 'network':
        return PixaImage(
          request: networkRequest(widget.post.imageUrl, targetWidth: 480),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          semanticLabel: 'PixaSource network demo image',
          placeholder: learnPlaceholder(context),
          progressBuilder: pixaProgressBuilder,
          errorBuilder: pixaErrorBuilder,
          transitionDuration: kLearnTransitionDuration,
        );
      case 'asset':
        return PixaImage.asset(
          'assets/pixa_sample.ppm',
          fit: BoxFit.contain,
          gaplessPlayback: true,
          semanticLabel: 'PixaSource asset demo image',
          placeholder: learnPlaceholder(context),
          errorBuilder: pixaErrorBuilder,
          transitionDuration: kLearnTransitionDuration,
        );
      case 'memory':
      case 'bytes':
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(Icons.memory_rounded, color: context.neu.accent, size: 32),
                const SizedBox(height: 10),
                Text(
                  'memory / bytes sources take a Uint8List at runtime — see '
                  'PixaImage.memory / PixaImage.bytes in the source code.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.neu.textSecondary,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        );
    }
    return const SizedBox.shrink();
  }
}

/// Demonstrates the low-res → full-res swap chain.
class LowResChainPreview extends StatelessWidget {
  const LowResChainPreview({super.key, required this.post});

  final ImagePost post;

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      child: PixaImage(
        request: networkRequest(
          post.imageUrl,
          targetWidth: 480,
        ).copyWith(lowRes: lowResRequest(post, pixels: 32)),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        semanticLabel: 'Low-res to full-res swap chain demo',
        placeholder: learnPlaceholder(context),
        progressBuilder: pixaProgressBuilder,
        errorBuilder: pixaErrorBuilder,
        transitionDuration: kLearnTransitionDuration,
      ),
    );
  }
}

/// Demonstrates cache-policy switching, prefetch and evict.
class CachePolicyPreview extends StatefulWidget {
  const CachePolicyPreview({super.key, required this.post});

  final ImagePost post;

  @override
  State<CachePolicyPreview> createState() => _CachePolicyPreviewState();
}

class _CachePolicyPreviewState extends State<CachePolicyPreview> {
  PixaCacheMode _mode = PixaCacheMode.memoryAndDisk;
  int _generation = 0;

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      actions: <Widget>[
        for (final PixaCacheMode mode in PixaCacheMode.values)
          ScenarioAction(
            label: mode.name,
            selected: _mode == mode,
            onPressed: () => setState(() {
              _mode = mode;
              _generation += 1;
            }),
          ),
        ScenarioAction(
          label: 'Prefetch',
          icon: Icons.speed_rounded,
          onPressed: () => Pixa.prefetch(
            PixaRequest.network(
              widget.post.imageUrl,
              cachePolicy: const PixaCachePolicy(mode: PixaCacheMode.diskOnly),
            ),
            target: PixaPrefetchTarget.diskOnly,
          ),
        ),
        ScenarioAction(
          label: 'Evict',
          icon: Icons.delete_outline_rounded,
          onPressed: () =>
              Pixa.evict(PixaRequest.network(widget.post.imageUrl)),
        ),
      ],
      child: PixaImage(
        key: ValueKey<String>('cache-${_mode.name}-$_generation'),
        request: PixaRequest.network(
          widget.post.imageUrl,
          cachePolicy: PixaCachePolicy(mode: _mode),
          targetSize: const PixaTargetSize(width: 480, height: 320),
        ),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        semanticLabel: 'Cache policy ${_mode.name} demo image',
        placeholder: learnPlaceholder(context),
        progressBuilder: pixaProgressBuilder,
        errorBuilder: pixaErrorBuilder,
        transitionDuration: kLearnTransitionDuration,
      ),
    );
  }
}

/// Demonstrates decoded prewarm via Flutter ImageCache.
class DecodedPrewarmPreview extends StatefulWidget {
  const DecodedPrewarmPreview({super.key, required this.post});

  final ImagePost post;

  @override
  State<DecodedPrewarmPreview> createState() => _DecodedPrewarmPreviewState();
}

class _DecodedPrewarmPreviewState extends State<DecodedPrewarmPreview> {
  String _status = 'Idle';

  Future<void> _prewarm() async {
    setState(() => _status = 'Prewarming…');
    try {
      await Pixa.precache(
        context,
        PixaRequest.network(
          widget.post.imageUrl,
          targetSize: const PixaTargetSize(width: 480, height: 320),
        ),
      );
      if (mounted) {
        setState(() => _status = 'Prewarmed into Flutter ImageCache');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _status = 'Failed: $error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScenarioPreviewFrame(
      height: 150,
      actions: <Widget>[
        ScenarioAction(
          label: 'Prewarm decoded',
          icon: Icons.whatshot_rounded,
          onPressed: _prewarm,
        ),
      ],
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                Icons.local_fire_department_outlined,
                color: context.neu.accent,
                size: 28,
              ),
              const SizedBox(height: 10),
              Text(
                _status,
                style: TextStyle(
                  color: context.neu.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
