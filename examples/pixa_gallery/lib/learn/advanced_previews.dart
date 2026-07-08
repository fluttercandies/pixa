import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';

import '../models/image_post.dart';
import '../pixa/pixa_recipes.dart';
import '../theme/neu_palette.dart';
import '../widgets/neu_controls.dart';
import 'display_previews.dart';

/// Demonstrates [PixaResponsiveImage] with a [PixaSourceSet] — the library's
/// layout-aware responsive image widget that picks the best candidate from a
/// set of sources based on available pixel dimensions.
class ResponsiveImagePreview extends StatelessWidget {
  const ResponsiveImagePreview({super.key, required this.post});

  final ImagePost post;

  @override
  Widget build(BuildContext context) {
    final sourceSet = PixaSourceSet(<PixaSourceSetCandidate>[
      PixaSourceSetCandidate.network(post.imageUrl, width: 320),
      PixaSourceSetCandidate.network(post.imageUrl, width: 640),
      PixaSourceSetCandidate.network(post.imageUrl, width: 1280),
    ]);
    return ScenarioPreviewFrame(
      child: PixaResponsiveImage(
        sourceSet: sourceSet,
        fit: BoxFit.cover,
        semanticLabel: 'PixaResponsiveImage demo',
        placeholder: PixaPlaceholder.color(context.neu.surface),
        progressBuilder: pixaProgressBuilder,
        errorBuilder: pixaErrorBuilder,
        transitionDuration: kLearnTransitionDuration,
      ),
    );
  }
}

/// Demonstrates [Pixa.analyze] — runtime color/palette analysis of encoded
/// image bytes. Shows average color, dominant color, and palette swatches.
class ColorAnalysisPreview extends StatefulWidget {
  const ColorAnalysisPreview({super.key, required this.post});

  final ImagePost post;

  @override
  State<ColorAnalysisPreview> createState() => _ColorAnalysisPreviewState();
}

class _ColorAnalysisPreviewState extends State<ColorAnalysisPreview> {
  PixaImageAnalysis? _analysis;
  bool _loading = false;
  String? _error;

  Future<void> _analyze() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await Pixa.analyze(
        PixaRequest.network(
          widget.post.imageUrl,
          cachePolicy: const PixaCachePolicy.cacheOnly(),
          priority: PixaPriority.high,
        ),
      );
      if (mounted) {
        setState(() {
          _analysis = result;
          _loading = false;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return ScenarioPreviewFrame(
      height: 200,
      actions: <Widget>[
        ScenarioAction(
          label: 'Analyze colors',
          icon: Icons.palette_rounded,
          onPressed: _loading ? null : _analyze,
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: _analysis == null
            ? Center(
                child: _loading
                    ? const NeuSpinner(size: 22)
                    : Text(
                        _error ?? 'Tap analyze to extract color palette',
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 13,
                        ),
                      ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Color Analysis',
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      _ColorSwatch(
                        label: 'Average',
                        argb: _analysis!.averageArgb,
                        palette: palette,
                      ),
                      const SizedBox(width: 10),
                      _ColorSwatch(
                        label: 'Dominant',
                        argb: _analysis!.dominantArgb,
                        palette: palette,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Palette (${_analysis!.paletteArgb.length} colors)',
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: <Widget>[
                      for (final c in _analysis!.paletteArgb)
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: Color(c),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: palette.divider,
                              width: 0.5,
                            ),
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

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.label,
    required this.argb,
    required this.palette,
  });

  final String label;
  final int argb;
  final NeuPalette palette;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Color(argb),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.divider, width: 0.5),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: palette.textMuted,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Demonstrates [PixaPipelineHandle] — the cancellable load handle returned
/// by [Pixa.pipeline.startLoad]. Shows how to start a load, display its
/// progress, and cancel it mid-flight.
class CancellableLoadPreview extends StatefulWidget {
  const CancellableLoadPreview({super.key, required this.post});

  final ImagePost post;

  @override
  State<CancellableLoadPreview> createState() => _CancellableLoadPreviewState();
}

class _CancellableLoadPreviewState extends State<CancellableLoadPreview> {
  PixaPipelineHandle? _handle;
  String _status = 'Idle';

  void _start() {
    setState(() => _status = 'Loading…');
    _handle = Pixa.pipeline.startLoad(
      PixaRequest.network(
        widget.post.imageUrl,
        cachePolicy: const PixaCachePolicy.noStore(),
        priority: PixaPriority.high,
      ),
    );
    _handle!.future
        .then((load) {
          try {
            setState(() {
              _status = 'Done: ${formatBytes(load.bytes.length)}';
            });
          } finally {
            load.dispose();
          }
        })
        .catchError((e) {
          if (mounted) {
            setState(() => _status = 'Cancelled or failed');
          }
        });
  }

  void _cancel() {
    _handle?.cancel();
    setState(() => _status = 'Cancelled');
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return ScenarioPreviewFrame(
      height: 130,
      actions: <Widget>[
        ScenarioAction(
          label: 'Start',
          icon: Icons.download_rounded,
          onPressed: _start,
        ),
        ScenarioAction(
          label: 'Cancel',
          icon: Icons.cancel_outlined,
          onPressed: _handle == null ? null : _cancel,
        ),
      ],
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.cancel_schedule_send_rounded,
                color: palette.accent,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'PixaPipelineHandle',
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _status,
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 13,
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

/// Demonstrates [Pixa.warmup] — batch cache warmup with a manifest of
/// requests. Useful for pre-populating the disk cache at app startup or
/// before a known navigation pattern.
class WarmupManifestPreview extends StatefulWidget {
  const WarmupManifestPreview({super.key, required this.post});

  final ImagePost post;

  @override
  State<WarmupManifestPreview> createState() => _WarmupManifestPreviewState();
}

class _WarmupManifestPreviewState extends State<WarmupManifestPreview> {
  String _status = 'Idle';

  Future<void> _warmup() async {
    setState(() => _status = 'Warming up…');
    final manifest = PixaCacheWarmupManifest(<PixaCacheWarmupEntry>[
      PixaCacheWarmupEntry(
        id: 'thumb-320',
        request: PixaRequest.network(
          widget.post.imageUrl,
          targetSize: const PixaTargetSize(width: 320),
        ),
        target: PixaPrefetchTarget.diskOnly,
      ),
      PixaCacheWarmupEntry(
        id: 'thumb-640',
        request: PixaRequest.network(
          widget.post.imageUrl,
          targetSize: const PixaTargetSize(width: 640),
        ),
        target: PixaPrefetchTarget.diskOnly,
      ),
    ]);
    final report = await Pixa.warmup(manifest);
    if (mounted) {
      setState(() {
        _status =
            'Warmed ${report.succeededIds.length}/${report.totalCount} entries'
            '${report.failures.isNotEmpty ? ", ${report.failureCount} failed" : ""}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return ScenarioPreviewFrame(
      height: 130,
      actions: <Widget>[
        ScenarioAction(
          label: 'Warmup',
          icon: Icons.whatshot_rounded,
          onPressed: _warmup,
        ),
      ],
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.local_fire_department_outlined,
                color: palette.accent,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Pixa.warmup(manifest)',
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _status,
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 13,
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
