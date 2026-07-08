import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';

import '../models/image_post.dart';
import '../theme/neu_palette.dart';
import '../widgets/neu_controls.dart';
import 'gallery_settings.dart';

/// A neumorphic settings page for the Pixa gallery.
///
/// Centralizes user preferences: theme mode, default image source,
/// tile target row height, Runtime auto-refresh toggle, and cache
/// management — all persisted via [GallerySettings].
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.settings});

  final GallerySettings settings;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late String _themeMode;
  late String _defaultSource;
  late double _targetRowHeight;
  late bool _runtimeAutoRefresh;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.settings.themeMode;
    _defaultSource = widget.settings.defaultSource;
    _targetRowHeight = widget.settings.targetRowHeight;
    _runtimeAutoRefresh = widget.settings.runtimeAutoRefresh;
    widget.settings.addListener(_onExternalChange);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onExternalChange);
    super.dispose();
  }

  void _onExternalChange() {
    if (!mounted) {
      return;
    }
    final s = widget.settings;
    setState(() {
      _themeMode = s.themeMode;
      _defaultSource = s.defaultSource;
      _targetRowHeight = s.targetRowHeight;
      _runtimeAutoRefresh = s.runtimeAutoRefresh;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return SafeArea(
      bottom: false,
      child: ListView(
        key: const ValueKey<String>('pixa-settings-scroll'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          _SettingsHeader(),
          const SizedBox(height: 14),
          // Appearance
          _SettingsCard(
            title: 'Appearance',
            icon: Icons.palette_rounded,
            children: <Widget>[
              _SettingsLabel('Theme'),
              const SizedBox(height: 8),
              NeuSegmented<String>(
                value: _themeMode,
                onChanged: (v) => widget.settings.themeMode = v,
                segments: const <NeuSegment<String>>[
                  NeuSegment<String>(value: 'system', label: 'System'),
                  NeuSegment<String>(value: 'light', label: 'Light'),
                  NeuSegment<String>(value: 'dark', label: 'Dark'),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Gallery defaults
          _SettingsCard(
            title: 'Gallery defaults',
            icon: Icons.photo_library_outlined,
            children: <Widget>[
              _SettingsLabel('Default source'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final s in SourceType.values)
                    NeuChip(
                      label: s.name,
                      selected: _defaultSource == s.name,
                      onTap: () => widget.settings.defaultSource = s.name,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _SettingsLabel('Tile target · ${_targetRowHeight.round()} px'),
              const SizedBox(height: 8),
              Slider(
                value: _targetRowHeight,
                min: 120,
                max: 280,
                divisions: 16,
                onChanged: (v) => setState(() => _targetRowHeight = v),
                onChangeEnd: (v) => widget.settings.targetRowHeight = v,
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Runtime
          _SettingsCard(
            title: 'Runtime',
            icon: Icons.monitor_heart_rounded,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Auto-refresh',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Live-update Runtime stats every 2s',
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  NeuToggle(
                    value: _runtimeAutoRefresh,
                    onChanged: (v) => widget.settings.runtimeAutoRefresh = v,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Cache management
          _SettingsCard(
            title: 'Cache management',
            icon: Icons.storage_rounded,
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  NeuButton(
                    onPressed: () async {
                      HapticFeedback.selectionClick();
                      final messenger = ScaffoldMessenger.of(context);
                      await Pixa.trimMemory();
                      if (mounted) {
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('Memory trimmed'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.compress_rounded, size: 16),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: const Text('Trim memory'),
                  ),
                  NeuButton(
                    onPressed: () async {
                      HapticFeedback.selectionClick();
                      final messenger = ScaffoldMessenger.of(context);
                      await Pixa.clearCache();
                      if (mounted) {
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('All cache cleared'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.delete_outline_rounded, size: 16),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: const Text('Clear all'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          // About
          _SettingsCard(
            title: 'About',
            icon: Icons.info_outline_rounded,
            children: <Widget>[
              _SettingsRow('Pixa version', Pixa.version),
              _SettingsRow(
                'Platform',
                PixaDebugInspector.snapshot()
                    .capabilities
                    .platformStatus
                    .platform,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return Row(
      children: <Widget>[
        Container(
          width: 42,
          height: 42,
          decoration: ShapeDecoration(
            color: palette.accentSoft,
            shape: const RoundedSuperellipseBorder(
              borderRadius: BorderRadius.all(Radius.circular(13)),
            ),
          ),
          child: Icon(Icons.settings_rounded, color: palette.accent, size: 22),
        ),
        const SizedBox(width: 12),
        Text(
          'Settings',
          style: TextStyle(
            color: palette.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }
}

class _SettingsLabel extends StatelessWidget {
  const _SettingsLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: palette.textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: palette.textSecondary, fontSize: 13),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return NeuCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, color: palette.accent, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}
