import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';

import '../pixa/pixa_recipes.dart';
import '../theme/neu_palette.dart';
import 'display_previews.dart';

/// Interactive [PixaConfig] tuning editor.
///
/// Shows the active configuration (from `Pixa.config`) as read-only values,
/// and lets the user live-tune the decoded ImageCache budget via
/// [Pixa.tuneDecodedCache], with live [Pixa.decodedCacheStats] feedback so
/// the effect of each adjustment is immediately visible. This is the same
/// surface a host app would use to right-size its decoded cache for a dense
/// gallery at runtime.
class ConfigTunerPreview extends StatefulWidget {
  const ConfigTunerPreview({super.key});

  @override
  State<ConfigTunerPreview> createState() => _ConfigTunerPreviewState();
}

class _ConfigTunerPreviewState extends State<ConfigTunerPreview> {
  late double _decodedEntries;
  late double _decodedBytesMb;
  PixaDecodedCacheStats? _stats;

  @override
  void initState() {
    super.initState();
    final cfg = Pixa.config;
    _decodedEntries = (cfg.decodedCacheMaximumSize ?? 1000).toDouble();
    _decodedBytesMb =
        ((cfg.decodedCacheMaximumSizeBytes ?? 100 * 1024 * 1024) /
                (1024 * 1024))
            .roundToDouble();
    _refreshStats();
  }

  void _refreshStats() {
    setState(() {
      _stats = Pixa.decodedCacheStats();
    });
  }

  void _applyDecodedTuning() {
    Pixa.tuneDecodedCache(
      maximumSize: _decodedEntries.round(),
      maximumSizeBytes: (_decodedBytesMb * 1024 * 1024).round(),
    );
    _refreshStats();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    final cfg = Pixa.config;
    final s = _stats;
    return ScenarioPreviewFrame(
      height: 300,
      actions: <Widget>[
        ScenarioAction(
          label: 'Apply',
          icon: Icons.check_rounded,
          onPressed: _applyDecodedTuning,
        ),
        ScenarioAction(
          label: 'Refresh',
          icon: Icons.refresh_rounded,
          onPressed: _refreshStats,
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _SectionLabel(text: 'Active config (read-only)'),
            const SizedBox(height: 4),
            _ConfigRow('memoryCacheBytes', formatBytes(cfg.memoryCacheBytes)),
            _ConfigRow('diskCacheBytes', formatBytes(cfg.diskCacheBytes)),
            _ConfigRow('networkConcurrency', '${cfg.networkConcurrency}'),
            _ConfigRow(
              'maxImageCompletionsPerFrame',
              '${cfg.maxImageCompletionsPerFrame}',
            ),
            const SizedBox(height: 10),
            _SectionLabel(text: 'Decoded ImageCache (live-tunable)'),
            const SizedBox(height: 6),
            _SliderRow(
              label: 'Entries',
              value: _decodedEntries,
              min: 50,
              max: 3000,
              onChanged: (v) => setState(() => _decodedEntries = v),
              display: '${_decodedEntries.round()}',
            ),
            const SizedBox(height: 6),
            _SliderRow(
              label: 'Budget',
              value: _decodedBytesMb,
              min: 16,
              max: 512,
              onChanged: (v) => setState(() => _decodedBytesMb = v),
              display: '${_decodedBytesMb.round()} MiB',
            ),
            if (s != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                'Live: ${s.currentSize}/${s.maximumSize} entries · '
                '${formatBytes(s.currentSizeBytes)}/${formatBytes(s.maximumSizeBytes)}',
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: palette.textMuted,
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _ConfigRow extends StatelessWidget {
  const _ConfigRow(this.configKey, this.value);
  final String configKey;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 190,
            child: Text(
              configKey,
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 11.5,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.display,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String display;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 60,
          child: Text(
            label,
            style: TextStyle(
              color: palette.textMuted,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Slider(value: value, min: min, max: max, onChanged: onChanged),
        ),
        SizedBox(
          width: 60,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: palette.accent,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }
}
