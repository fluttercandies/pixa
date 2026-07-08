import 'package:flutter/material.dart';
import 'package:pixa/pixa_debug.dart';

import '../models/image_post.dart';
import '../theme/neu_palette.dart';
import '../widgets/neu_controls.dart';
import '../widgets/neu_navigation.dart';
import '../widgets/neu_surface.dart';
import 'gallery_slivers.dart';

/// The raised workbench header above the gallery feed.
///
/// Surfaces the brand, the runtime/cache status, source selector, layout
/// selector and the row-height slider. All controls are callback-driven so
/// the owning page owns the actual state.
class GalleryWorkbench extends StatelessWidget {
  const GalleryWorkbench({
    super.key,
    required this.snapshot,
    required this.selectedSource,
    required this.onSourceChanged,
    required this.layout,
    required this.onLayoutChanged,
    required this.targetRowHeight,
    required this.onTargetRowHeightChanged,
    required this.onPrefetch,
    required this.onCacheStats,
    required this.onTrimMemory,
  });

  final PixaDebugSnapshot snapshot;
  final SourceType selectedSource;
  final ValueChanged<SourceType> onSourceChanged;
  final GalleryLayout layout;
  final ValueChanged<GalleryLayout> onLayoutChanged;
  final double targetRowHeight;
  final ValueChanged<double> onTargetRowHeightChanged;
  final VoidCallback onPrefetch;
  final VoidCallback onCacheStats;
  final VoidCallback onTrimMemory;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    final PixaCacheStats? cache = snapshot.cacheStats;
    final PixaSchedulerStats? scheduler = snapshot.schedulerStats;
    final bool runtimeReady =
        snapshot.capabilities.platformStatus.runtimeAvailable &&
        snapshot.platformSelfCheck.passed;

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      sliver: SliverToBoxAdapter(
        child: RepaintBoundary(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              NeuCard(
                elevation: NeuElevation.medium,
                shape: NeuShape.convex,
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Container(
                          width: 44,
                          height: 44,
                          decoration: ShapeDecoration(
                            color: palette.accent,
                            shape: const RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.all(
                                Radius.circular(14),
                              ),
                            ),
                          ),
                          child: const Icon(
                            Icons.bolt_rounded,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                'Gallery Workbench',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  color: palette.textPrimary,
                                  letterSpacing: -0.4,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${selectedSource.label} · ${layoutLabel(layout)}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: palette.accent,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Production image loading, cache, processing and runtime inspection.',
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: NeuStat(
                            label: 'RUNTIME READY',
                            value: runtimeReady ? 'yes' : 'unavailable',
                            icon: runtimeReady
                                ? Icons.check_circle_rounded
                                : Icons.error_outline_rounded,
                            tone: runtimeReady
                                ? NeuStatTone.success
                                : NeuStatTone.warning,
                          ),
                        ),
                        Container(
                          width: 1,
                          height: 38,
                          color: palette.divider,
                          margin: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        Expanded(
                          child: NeuStat(
                            label: 'CACHE HIT',
                            value:
                                '${((cache?.hitRate ?? 0) * 100).clamp(0, 999).toStringAsFixed(1)}%',
                            icon: Icons.storage_rounded,
                            tone: NeuStatTone.accent,
                          ),
                        ),
                        Container(
                          width: 1,
                          height: 38,
                          color: palette.divider,
                          margin: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        Expanded(
                          child: NeuStat(
                            label: 'ACTIVE LOADS',
                            value: (scheduler?.activeRuntimeLoads ?? 0)
                                .toString(),
                            icon: Icons.cloud_download_rounded,
                            tone: NeuStatTone.neutral,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: <Widget>[
                        NeuButton(
                          onPressed: onPrefetch,
                          accent: true,
                          icon: const Icon(Icons.speed_rounded),
                          child: const Text('Prefetch window'),
                        ),
                        NeuButton(
                          onPressed: onCacheStats,
                          icon: const Icon(Icons.analytics_outlined),
                          child: const Text('Cache stats'),
                        ),
                        NeuIconButton(
                          icon: Icons.compress_rounded,
                          tooltip: 'Trim memory',
                          onPressed: onTrimMemory,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              NeuCard(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _Label(icon: Icons.source_outlined, text: 'Source'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final SourceType source in SourceType.values)
                          NeuChip(
                            label: source.name,
                            selected: source == selectedSource,
                            onTap: () => onSourceChanged(source),
                            icon: Icons.image_outlined,
                            selectedIcon: Icons.image_rounded,
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _Label(icon: Icons.dashboard_outlined, text: 'Layout'),
                    const SizedBox(height: 10),
                    NeuSegmented<GalleryLayout>(
                      value: layout,
                      onChanged: onLayoutChanged,
                      segments: const <NeuSegment<GalleryLayout>>[
                        NeuSegment<GalleryLayout>(
                          value: GalleryLayout.flexRows,
                          label: 'Flex rows',
                          icon: Icons.view_stream_rounded,
                        ),
                        NeuSegment<GalleryLayout>(
                          value: GalleryLayout.masonry,
                          label: 'Masonry',
                          icon: Icons.dashboard_customize_rounded,
                        ),
                        NeuSegment<GalleryLayout>(
                          value: GalleryLayout.denseGrid,
                          label: 'Grid',
                          icon: Icons.grid_view_rounded,
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _Label(
                      icon: Icons.height_outlined,
                      text: 'Tile target · ${targetRowHeight.round()} px',
                    ),
                    const SizedBox(height: 10),
                    NeuSliderRow(
                      value: targetRowHeight,
                      min: 120,
                      max: 280,
                      onChanged: onTargetRowHeightChanged,
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

class _Label extends StatelessWidget {
  const _Label({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return Row(
      children: <Widget>[
        Icon(icon, size: 15, color: palette.textMuted),
        const SizedBox(width: 6),
        Text(
          text.toUpperCase(),
          style: TextStyle(
            color: palette.textMuted,
            fontWeight: FontWeight.w700,
            fontSize: 11,
            letterSpacing: 0.6,
          ),
        ),
      ],
    );
  }
}

/// A slider inside a concave neumorphic track.
class NeuSliderRow extends StatelessWidget {
  const NeuSliderRow({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return NeuSurface(
      shape: NeuShape.concave,
      elevation: NeuElevation.low,
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Slider(value: value, min: min, max: max, onChanged: onChanged),
    );
  }
}

/// Display label for a [SourceType], shown in the workbench header.
String sourceTypeLabel(SourceType source) {
  switch (source) {
    case SourceType.yande:
      return 'yande.re';
    case SourceType.zerochan:
      return 'zerochan';
    case SourceType.nekosia:
      return 'nekosia.cat';
    case SourceType.konachan:
      return 'konachan';
  }
}

/// Display label for a [GalleryLayout], shown in the workbench header.
String layoutLabel(GalleryLayout layout) {
  switch (layout) {
    case GalleryLayout.flexRows:
      return 'Flex rows';
    case GalleryLayout.masonry:
      return 'Masonry';
    case GalleryLayout.denseGrid:
      return 'Grid';
  }
}

/// Friendly [SourceType] label extension.
extension SourceTypeLabel on SourceType {
  /// Human-readable source label for the workbench header.
  String get label => sourceTypeLabel(this);
}
