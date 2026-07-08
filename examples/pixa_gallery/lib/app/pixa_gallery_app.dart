import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pixa/pixa.dart';

import '../diagnostics/diagnostics_page.dart';
import '../config/image_config.dart';
import '../gallery/gallery_page.dart';
import '../learn/learn_page.dart';
import '../models/image_post.dart';
import '../theme/neu_palette.dart';
import '../theme/neu_theme.dart';
import '../widgets/neu_controls.dart';
import '../widgets/neu_navigation.dart';
import 'gallery_routes.dart';
import 'gallery_settings.dart';
import 'settings_page.dart';

/// Root [MaterialApp] for the Pixa gallery workbench.
class PixaGalleryApp extends StatefulWidget {
  const PixaGalleryApp({
    super.key,
    this.initialPosts = const <ImagePost>[],
    this.loadOnStart = true,
    this.initialTab = GalleryTab.gallery,
    this.initialBrightness,
    this.settings,
    this.navigatorObservers = const <NavigatorObserver>[],
  });

  final List<ImagePost> initialPosts;
  final bool loadOnStart;
  final GalleryTab initialTab;
  final Brightness? initialBrightness;
  final GallerySettings? settings;
  final List<NavigatorObserver> navigatorObservers;

  @override
  State<PixaGalleryApp> createState() => _PixaGalleryAppState();
}

class _PixaGalleryAppState extends State<PixaGalleryApp>
    with SingleTickerProviderStateMixin {
  late GalleryTab _tab = widget.initialTab;
  late Brightness _brightness = _resolveBrightness();
  late final ValueNotifier<List<ImagePost>> _feed =
      ValueNotifier<List<ImagePost>>(<ImagePost>[]);
  // Drives the smooth cross-fade overlay during a theme switch.
  late final AnimationController _themeSwitchController;

  /// Resolves the effective brightness from the persisted theme mode,
  /// falling back to the widget override or the platform brightness.
  Brightness _resolveBrightness() {
    final mode = widget.settings?.themeMode ?? 'system';
    switch (mode) {
      case 'light':
        return Brightness.light;
      case 'dark':
        return Brightness.dark;
      default:
        return widget.initialBrightness ??
            WidgetsBinding.instance.platformDispatcher.platformBrightness;
    }
  }

  void _onSettingsChanged() {
    if (!mounted) {
      return;
    }
    final next = _resolveBrightness();
    if (next != _brightness) {
      _applyBrightness(next);
    }
  }

  @override
  void initState() {
    super.initState();
    _feed.value = widget.initialPosts;
    _themeSwitchController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    widget.settings?.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    widget.settings?.removeListener(_onSettingsChanged);
    _feed.dispose();
    _themeSwitchController.dispose();
    super.dispose();
  }

  void _applyBrightness(Brightness next) {
    final NeuPalette oldPalette = _brightness == Brightness.dark
        ? NeuPalette.dark
        : NeuPalette.light;
    _themeSwitchController.value = 0.0;
    setState(() => _brightness = next);
    _runThemeSwitch(oldPalette);
  }

  void _toggleBrightness() {
    HapticFeedback.selectionClick();
    // Persist the explicit choice so it survives restarts.
    final next = _brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    final settings = widget.settings;
    if (settings != null) {
      settings.themeMode = next == Brightness.dark ? 'dark' : 'light';
    } else {
      _applyBrightness(next);
    }
  }

  void _runThemeSwitch(NeuPalette fromPalette) {
    final NeuPalette toPalette = _brightness == Brightness.dark
        ? NeuPalette.dark
        : NeuPalette.light;
    final Animation<double> curve = CurvedAnimation(
      parent: _themeSwitchController,
      curve: Curves.easeOutCubic,
    );
    _themeSwitchController.forward(from: 0.0);
    // Hold the overlay reference so the fade-out layer reads the tween.
    _activeSwitchOverlay = _ThemeSwitchOverlay(
      animation: curve,
      from: fromPalette.base,
      to: toPalette.base,
    );
    _themeSwitchController.addStatusListener(_onSwitchDone);
  }

  void _onSwitchDone(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _themeSwitchController.removeStatusListener(_onSwitchDone);
      setState(() {
        _activeSwitchOverlay = null;
      });
    }
  }

  // The currently-visible theme-switch overlay, null when idle.
  _ThemeSwitchOverlay? _activeSwitchOverlay;

  @override
  void didUpdateWidget(covariant PixaGalleryApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When the driver rebinds the app with a different initial tab (e.g.
    // integration tests swap destinations via pumpWidget), follow the new
    // intent instead of keeping the first mount's selection.
    if (widget.initialTab != oldWidget.initialTab) {
      _tab = widget.initialTab;
    }
    if (widget.initialPosts != oldWidget.initialPosts) {
      _feed.value = widget.initialPosts;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pixa Gallery',
      debugShowCheckedModeBanner: false,
      theme: NeuTheme.light(),
      darkTheme: NeuTheme.dark(),
      themeMode: _brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      navigatorObservers: widget.navigatorObservers,
      builder: (BuildContext context, Widget? child) {
        // Stack the smooth theme-switch overlay above the whole tree so the
        // dark/light transition cross-fades instead of snapping.
        return Stack(children: <Widget>[?child, ?_activeSwitchOverlay]);
      },
      home: _HomeShell(
        tab: _tab,
        onTabChanged: (GalleryTab t) => setState(() => _tab = t),
        feed: _feed,
        initialPosts: widget.initialPosts,
        loadOnStart: widget.loadOnStart,
        brightness: _brightness,
        onToggleBrightness: _toggleBrightness,
        settings: widget.settings,
      ),
    );
  }
}

/// A full-screen overlay that cross-fades the old theme's base colour into
/// transparency as the new theme paints underneath, giving the dark/light
/// switch a smooth, production-grade transition instead of a hard snap.
class _ThemeSwitchOverlay extends StatelessWidget {
  const _ThemeSwitchOverlay({
    required this.animation,
    required this.from,
    required this.to,
  });

  final Animation<double> animation;
  final Color from;
  final Color to;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: animation,
          builder: (BuildContext context, Widget? child) {
            // The overlay starts opaque in the old base colour and fades out
            // to reveal the new theme beneath.
            return ColoredBox(
              color: Color.lerp(
                from,
                to,
                animation.value,
              )!.withValues(alpha: 1.0 - animation.value),
              child: child,
            );
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _HomeShell extends StatelessWidget {
  const _HomeShell({
    required this.tab,
    required this.onTabChanged,
    required this.feed,
    required this.initialPosts,
    required this.loadOnStart,
    required this.brightness,
    required this.onToggleBrightness,
    this.settings,
  });

  final GalleryTab tab;
  final ValueChanged<GalleryTab> onTabChanged;
  final ValueNotifier<List<ImagePost>> feed;
  final List<ImagePost> initialPosts;
  final bool loadOnStart;
  final Brightness brightness;
  final VoidCallback onToggleBrightness;
  final GallerySettings? settings;

  /// Resolves the persisted default source name to a [SourceType].
  SourceType _resolveInitialSource() {
    final name = settings?.defaultSource;
    if (name == null) {
      return ImageConfig.currentSource;
    }
    return SourceType.values.firstWhere(
      (SourceType s) => s.name == name,
      orElse: () => ImageConfig.currentSource,
    );
  }

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    final bool wide = MediaQuery.sizeOf(context).width >= 900;

    return Scaffold(
      backgroundColor: palette.base,
      body: SafeArea(
        child: wide
            ? Row(
                children: <Widget>[
                  _buildRail(palette),
                  const VerticalDivider(width: 1),
                  Expanded(child: _buildBody(context)),
                ],
              )
            : _buildBody(context),
      ),
      bottomNavigationBar: wide
          ? null
          : NeuBottomNav(
              destinations: GalleryTab.values
                  .map(
                    (GalleryTab t) => PixaDestination(
                      value: t,
                      label: t.label,
                      icon: t.icon,
                      selectedIcon: t.selectedIcon,
                    ),
                  )
                  .toList(),
              value: tab,
              onChanged: (Object? v) {
                if (v is GalleryTab) {
                  onTabChanged(v);
                }
              },
            ),
    );
  }

  Widget _buildRail(NeuPalette palette) {
    return SizedBox(
      width: 96,
      child: NeuRail(
        destinations: GalleryTab.values
            .map(
              (GalleryTab t) => PixaDestination(
                value: t,
                label: t.label,
                icon: t.icon,
                selectedIcon: t.selectedIcon,
              ),
            )
            .toList(),
        value: tab,
        onChanged: (Object? v) {
          if (v is GalleryTab) {
            onTabChanged(v);
          }
        },
        header: Column(
          children: <Widget>[
            Container(
              width: 40,
              height: 40,
              decoration: ShapeDecoration(
                color: palette.accent,
                shape: const RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.all(Radius.circular(13)),
                ),
              ),
              child: const Icon(Icons.bolt_rounded, color: Colors.white),
            ),
            const SizedBox(height: 10),
            NeuIconButton(
              icon: brightness == Brightness.dark
                  ? Icons.light_mode_rounded
                  : Icons.dark_mode_rounded,
              tooltip: 'Toggle theme',
              size: 42,
              iconSize: 18,
              onPressed: onToggleBrightness,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return Stack(
      children: <Widget>[
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: KeyedSubtree(
            key: ValueKey<GalleryTab>(tab),
            child: _buildTab(),
          ),
        ),
        if (MediaQuery.sizeOf(context).width < 900)
          Positioned(top: 16, right: 16, child: _buildThemeToggle(context)),
      ],
    );
  }

  Widget _buildTab() {
    switch (tab) {
      case GalleryTab.gallery:
        return GalleryPage(
          initialPosts: initialPosts,
          loadOnStart: loadOnStart,
          initialSource: _resolveInitialSource(),
          onPostsChanged: (List<ImagePost> posts) => feed.value = posts,
        );
      case GalleryTab.learn:
        return ValueListenableBuilder<List<ImagePost>>(
          valueListenable: feed,
          builder: (BuildContext context, List<ImagePost> value, _) {
            return LearnPage(feed: value);
          },
        );
      case GalleryTab.diagnostics:
        return DiagnosticsPage(
          initialAutoRefresh: settings?.runtimeAutoRefresh,
        );
      case GalleryTab.settings:
        return settings != null
            ? SettingsPage(settings: settings!)
            : const Center(child: Text('Settings unavailable'));
    }
  }

  Widget _buildThemeToggle(BuildContext context) {
    return NeuIconButton(
      icon: brightness == Brightness.dark
          ? Icons.light_mode_rounded
          : Icons.dark_mode_rounded,
      tooltip: 'Toggle theme',
      size: 46,
      iconSize: 20,
      onPressed: onToggleBrightness,
    );
  }
}

// ignore: unused_element
void _ensurePixaConfigured() {
  if (!Pixa.isConfigured) {
    Pixa.configure();
  }
}
