import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';

import '../diagnostics/pixa_event_capture.dart';
import '../models/image_post.dart';
import '../pixa/pixa_recipes.dart';
import '../theme/neu_palette.dart';
import '../widgets/neu_controls.dart';
import 'display_previews.dart';

/// Demonstrates the live [PixaCacheStats] / [PixaDecodedCacheStats] surface
/// that [Pixa.cacheStats], [Pixa.decodedCacheStats] and [PixaDebugInspector]
/// expose — the same numbers the Runtime tab inspects.
class InspectorStatsPreview extends StatefulWidget {
  const InspectorStatsPreview({super.key, required this.post});

  final ImagePost post;

  @override
  State<InspectorStatsPreview> createState() => _InspectorStatsPreviewState();
}

class _InspectorStatsPreviewState extends State<InspectorStatsPreview> {
  PixaCacheStats? _cache;
  PixaDecodedCacheStats? _decoded;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _cache = Pixa.cacheStats();
      _decoded = Pixa.decodedCacheStats();
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    final c = _cache;
    final d = _decoded;
    return ScenarioPreviewFrame(
      height: 150,
      actions: <Widget>[
        ScenarioAction(
          label: 'Refresh stats',
          icon: Icons.refresh_rounded,
          onPressed: _refresh,
        ),
        ScenarioAction(
          label: 'Trim memory',
          icon: Icons.compress_rounded,
          onPressed: () async {
            await Pixa.trimMemory();
            _refresh();
          },
        ),
        ScenarioAction(
          label: 'Clear cache',
          icon: Icons.cleaning_services_outlined,
          onPressed: () async {
            await Pixa.clearCache();
            _refresh();
          },
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: c == null || d == null
            ? const Center(child: NeuSpinner(size: 22))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _StatLine('memory bytes', formatBytes(c.memoryBytes)),
                  _StatLine(
                    'hit rate',
                    '${(c.hitRate * 100).toStringAsFixed(1)}%',
                  ),
                  _StatLine('disk writes', '${c.diskWrites}'),
                  _StatLine(
                    'decoded',
                    '${d.currentSize}/${d.maximumSize} · '
                        '${formatBytes(d.currentSizeBytes)}',
                  ),
                  const Spacer(),
                  Text(
                    'Pixa.cacheStats() · Pixa.decodedCacheStats() · '
                    'PixaDebugInspector.snapshot()',
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _StatLine extends StatelessWidget {
  const _StatLine(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Demonstrates the [PixaObserver] event bus: every load, cache lookup,
/// decode, process and failure emitted by the pipeline is mirrored into the
/// app-scoped [PixaEventCapture] (registered in `main.dart` via
/// `PixaConfig(observers:)`). This recipe visualises that live stream.
class ObserverEventsPreview extends StatefulWidget {
  const ObserverEventsPreview({super.key, required this.post});

  final ImagePost post;

  @override
  State<ObserverEventsPreview> createState() => _ObserverEventsPreviewState();
}

class _ObserverEventsPreviewState extends State<ObserverEventsPreview> {
  @override
  void initState() {
    super.initState();
    PixaEventCapture.instance.addListener(_onChange);
  }

  @override
  void dispose() {
    PixaEventCapture.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _trigger() async {
    await Pixa.prefetch(
      PixaRequest.network(
        widget.post.imageUrl,
        cachePolicy: const PixaCachePolicy.noStore(),
        priority: PixaPriority.high,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    final events = PixaEventCapture.instance.events;
    final total = PixaEventCapture.instance.total;
    return ScenarioPreviewFrame(
      height: 190,
      actions: <Widget>[
        ScenarioAction(
          label: 'Trigger event',
          icon: Icons.flash_on_rounded,
          onPressed: _trigger,
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.stream_rounded, size: 14, color: palette.accent),
                const SizedBox(width: 6),
                Text(
                  '$total events observed',
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: events.isEmpty
                  ? Center(
                      child: Text(
                        'Tap "Trigger event" to emit pipeline events.',
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: events.length,
                      reverse: true,
                      itemBuilder: (BuildContext context, int index) {
                        // newest last in source -> read from the end.
                        final e = events[events.length - 1 - index];
                        return _EventRow(event: e);
                      },
                      separatorBuilder: (BuildContext context, int index) =>
                          const SizedBox(height: 2),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});
  final PixaEvent event;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    final tone = _stageTone(event.stage, palette);
    return Row(
      children: <Widget>[
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 64,
          child: Text(
            event.stage.name,
            style: TextStyle(
              color: tone,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Text(
            event.name,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 10.5,
              fontFamily: 'monospace',
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text(
          '#${event.requestId}',
          style: TextStyle(
            color: palette.textMuted,
            fontSize: 10,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Color _stageTone(PixaStage stage, NeuPalette palette) {
    switch (stage) {
      case PixaStage.complete:
        return palette.success;
      case PixaStage.cancel:
        return palette.textMuted;
      case PixaStage.fetch:
      case PixaStage.decode:
      case PixaStage.process:
        return palette.accent;
      case PixaStage.cacheLookup:
      case PixaStage.cacheWrite:
      case PixaStage.request:
        return palette.textSecondary;
    }
  }
}
