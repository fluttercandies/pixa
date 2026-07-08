import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/image_post.dart';
import '../theme/neu_palette.dart';
import '../widgets/neu_controls.dart';
import '../widgets/neu_navigation.dart';
import '../widgets/neu_surface.dart';
import 'advanced_previews.dart';
import 'cache_previews.dart';
import 'config_previews.dart';
import 'config_tuner_preview.dart';
import 'display_previews.dart';
import 'processor_previews.dart';
import 'scenario_model.dart';
import 'sources_previews.dart';

/// The Learn page: production recipes for every public Pixa capability,
/// grouped by capability area. Each group header is tappable to collapse or
/// expand its scenario cards, reducing the cognitive load of the long
/// recipe catalog.
class LearnPage extends StatefulWidget {
  const LearnPage({super.key, required this.feed});

  final List<ImagePost> feed;

  @override
  State<LearnPage> createState() => _LearnPageState();
}

class _LearnPageState extends State<LearnPage> {
  /// Collapse state keyed by group title. All groups start expanded.
  final Map<String, bool> _collapsed = <String, bool>{};
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _groupKeys = <String, GlobalKey>{};
  String _searchQuery = '';

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  bool _isCollapsed(String title) => _collapsed[title] ?? false;

  void _toggleGroup(String title) {
    HapticFeedback.selectionClick();
    setState(() {
      _collapsed[title] = !_isCollapsed(title);
    });
  }

  GlobalKey _keyFor(String title) =>
      _groupKeys.putIfAbsent(title, () => GlobalKey());

  void _jumpToGroup(String title) {
    HapticFeedback.selectionClick();
    // Expand if collapsed so the jump reveals content.
    if (_isCollapsed(title)) {
      setState(() => _collapsed[title] = false);
    }
    final key = _keyFor(title);
    final ctx = key.currentContext;
    if (ctx != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
          alignment: 0.0,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ImagePost post = learnImagePost(widget.feed);
    final ImagePost alt = learnImagePost(widget.feed, index: 1);
    final List<LearnGroup> allGroups = _groups(post, alt);
    final int totalCount = allGroups.fold<int>(
      0,
      (int total, LearnGroup g) => total + g.scenarios.length,
    );

    // Filter groups by search query.
    final q = _searchQuery.toLowerCase();
    final List<LearnGroup> groups;
    if (q.isEmpty) {
      groups = allGroups;
    } else {
      groups = allGroups
          .map((g) {
            final filtered = g.scenarios.where((s) {
              return s.title.toLowerCase().contains(q) ||
                  s.subtitle.toLowerCase().contains(q) ||
                  s.apiNote.toLowerCase().contains(q);
            }).toList();
            return LearnGroup(title: g.title, scenarios: filtered);
          })
          .where((g) => g.scenarios.isNotEmpty)
          .toList();
    }
    final int visibleCount = groups.fold<int>(
      0,
      (int total, LearnGroup g) => total + g.scenarios.length,
    );

    return CustomScrollView(
      key: const ValueKey<String>('pixa-scenarios-scroll'),
      controller: _scrollController,
      slivers: <Widget>[
        SliverToBoxAdapter(child: _LearnHeader(count: totalCount)),
        // Search bar.
        SliverToBoxAdapter(
          child: _LearnSearchBar(
            query: _searchQuery,
            onChanged: (v) => setState(() => _searchQuery = v),
            resultCount: visibleCount,
          ),
        ),
        if (q.isEmpty)
          // Quick-jump chip bar for instant navigation to any group.
          SliverToBoxAdapter(
            child: _QuickJumpBar(
              groups: allGroups
                  .map((g) => (title: g.title, icon: g.scenarios.first.icon))
                  .toList(),
              onJump: _jumpToGroup,
            ),
          ),
        if (visibleCount == 0)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No recipes match "$_searchQuery".',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.neu.textMuted,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          )
        else
          for (final LearnGroup group in groups) ...<Widget>[
            SliverToBoxAdapter(
              key: _keyFor(group.title),
              child: _GroupHeader(
                title: group.title,
                count: group.scenarios.length,
                collapsed: _isCollapsed(group.title),
                onTap: () => _toggleGroup(group.title),
              ),
            ),
            if (!_isCollapsed(group.title))
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                sliver: SliverList.separated(
                  itemCount: group.scenarios.length,
                  separatorBuilder: (BuildContext context, int index) =>
                      const SizedBox(height: 14),
                  itemBuilder: (BuildContext context, int index) {
                    final LearnScenario s = group.scenarios[index];
                    return _ScenarioCard(scenario: s);
                  },
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
          ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  List<LearnGroup> _groups(ImagePost post, ImagePost alt) {
    return <LearnGroup>[
      LearnGroup(
        title: 'Display APIs',
        scenarios: <LearnScenario>[
          LearnScenario(
            title: 'PixaImage',
            subtitle: 'Widget surface with fit, progress and transition',
            icon: Icons.image_outlined,
            apiNote:
                'API: PixaImage(request:) · PixaPlaceholder · transitionDuration',
            builder: (_) => DisplayWidgetPreview(post: post),
          ),
          LearnScenario(
            title: 'Provider',
            subtitle: 'ImageProvider compatibility for Flutter Image',
            icon: Icons.key_outlined,
            apiNote: 'API: PixaProvider.network(file/asset/memory/bytes)',
            builder: (_) => DisplayProviderPreview(post: post),
          ),
          LearnScenario(
            title: 'Controller',
            subtitle: 'Reload, cancel, pause and resume',
            icon: Icons.tune_rounded,
            apiNote: 'API: PixaController.reload/cancel/pause/resume',
            builder: (_) => DisplayControllerPreview(post: post),
          ),
          LearnScenario(
            title: 'Pipeline load',
            subtitle: 'Low-level bytes with typed metadata',
            icon: Icons.memory_rounded,
            apiNote: 'API: Pixa.pipeline.load() -> PixaPipelineLoad',
            builder: (_) => DisplayPipelinePreview(post: post),
          ),
        ],
      ),
      LearnGroup(
        title: 'Sources',
        scenarios: <LearnScenario>[
          LearnScenario(
            title: 'Network & asset',
            subtitle: 'Network and asset source on one stage',
            icon: Icons.folder_open_outlined,
            apiNote:
                'API: PixaImage.network / PixaImage.asset / PixaSource.network',
            builder: (_) => SourceBundlePreview(post: post),
          ),
          LearnScenario(
            title: 'File source',
            subtitle: 'Load from the device filesystem',
            icon: Icons.insert_drive_file_outlined,
            apiNote: 'API: PixaImage.file(path) · PixaSource.file',
            builder: (_) => const FileSourcePreview(),
          ),
          LearnScenario(
            title: 'Memory source',
            subtitle: 'Load a runtime Uint8List object',
            icon: Icons.memory_rounded,
            apiNote: 'API: PixaImage.memory(id, bytes) · PixaSource.memory',
            builder: (_) => const MemorySourcePreview(),
          ),
          LearnScenario(
            title: 'Bytes source',
            subtitle: 'Raw encoded bytes with format hint',
            icon: Icons.data_object_rounded,
            apiNote: 'API: PixaImage.bytes(bytes) · PixaSource.bytes',
            builder: (_) => const BytesSourcePreview(),
          ),
        ],
      ),
      LearnGroup(
        title: 'Cache and Prefetch',
        scenarios: <LearnScenario>[
          LearnScenario(
            title: 'Low-res chain',
            subtitle: 'Preview swaps to the full request',
            icon: Icons.swap_vert_rounded,
            apiNote: 'API: PixaRequest(lowRes:) · PixaSource.exifThumbnail',
            builder: (_) => LowResChainPreview(post: post),
          ),
          LearnScenario(
            title: 'Cache policy',
            subtitle: 'All 8 cache modes, prefetch and evict',
            icon: Icons.storage_rounded,
            apiNote:
                'API: PixaCachePolicy(mode:) · PixaCacheMode · Pixa.prefetch/evict',
            builder: (_) => CachePolicyPreview(post: post),
          ),
          LearnScenario(
            title: 'Decoded prewarm',
            subtitle: 'Flutter ImageCache integration',
            icon: Icons.whatshot_outlined,
            apiNote: 'API: Pixa.precache() · Pixa.tuneDecodedCache()',
            builder: (_) => DecodedPrewarmPreview(post: post),
          ),
          LearnScenario(
            title: 'Runtime inspector',
            subtitle: 'Live cache, decoded and scheduler stats',
            icon: Icons.analytics_outlined,
            apiNote:
                'API: Pixa.cacheStats() · Pixa.decodedCacheStats() · PixaDebugInspector',
            builder: (_) => InspectorStatsPreview(post: post),
          ),
          LearnScenario(
            title: 'Observer events',
            subtitle: 'Live pipeline event stream from the observer bus',
            icon: Icons.stream_rounded,
            apiNote:
                'API: PixaConfig(observers:) · PixaObserver.onPixaEvent · PixaEvent',
            builder: (_) => ObserverEventsPreview(post: post),
          ),
          LearnScenario(
            title: 'Config tuner',
            subtitle: 'Live-tune decoded cache budget with instant feedback',
            icon: Icons.tune_rounded,
            apiNote:
                'API: PixaConfig · Pixa.tuneDecodedCache(maximumSize:maximumSizeBytes:) · Pixa.config',
            builder: (_) => const ConfigTunerPreview(),
          ),
        ],
      ),
      LearnGroup(
        title: 'Processing and Metadata',
        scenarios: <LearnScenario>[
          LearnScenario(
            title: 'Processor lab',
            subtitle: 'Every public Rust processor helper',
            icon: Icons.auto_fix_high_rounded,
            apiNote:
                'API: PixaProcessors.resize/crop/rotate/blur/grayscale/...',
            builder: (_) => ProcessorLabPreview(post: post),
          ),
          LearnScenario(
            title: 'Thumbnail',
            subtitle: 'No-upscale runtime transform',
            icon: Icons.crop_free_rounded,
            apiNote: 'API: PixaProcessors.thumbnail(width, height)',
            builder: (_) => ThumbnailPreview(post: post),
          ),
          LearnScenario(
            title: 'Metadata',
            subtitle: 'Header probe without full decode',
            icon: Icons.science_outlined,
            apiNote: 'API: PixaImageMetadata.parseEncoded(bytes)',
            builder: (_) => MetadataPreview(post: post),
          ),
        ],
      ),
      LearnGroup(
        title: 'Large, Animated and Video',
        scenarios: <LearnScenario>[
          LearnScenario(
            title: 'Large viewer',
            subtitle: 'Tiled pan and zoom',
            icon: Icons.open_in_full_rounded,
            apiNote:
                'API: PixaLargeImage · PixaLargeImageController · tileMode',
            builder: (_) => LargeImageInlinePreview(post: alt),
          ),
          LearnScenario(
            title: 'Progressive JPEG',
            subtitle: 'Streaming preview event',
            icon: Icons.broken_image_outlined,
            apiNote:
                'API: PixaProgressivePreview · PixaProgress.fetch.progressivePreview',
            builder: (_) => const ProgressiveJpegPreview(),
          ),
          LearnScenario(
            title: 'Animated GIF',
            subtitle: 'Playback controller',
            icon: Icons.gif_box_outlined,
            apiNote: 'API: PixaAnimationController.play/pause/stop',
            builder: (_) => AnimatedGifPreview(
              url:
                  'https://media0.giphy.com/media/3oEjI6SIIHBdRxXI40/giphy.gif',
            ),
          ),
          LearnScenario(
            title: 'Animated WebP',
            subtitle: 'Engine-backed animation path',
            icon: Icons.animation_rounded,
            apiNote:
                'API: PixaImage(animationController:) · PixaAnimationOptions',
            builder: (_) => AnimatedWebpPreview(
              url: 'https://www.gstatic.com/webp/gallery/4.webp',
            ),
          ),
          LearnScenario(
            title: 'Video frame',
            subtitle: 'Platform backend or capability gate',
            icon: Icons.video_file_outlined,
            apiNote: 'API: PixaImage.videoFrame(locator, timestamp:)',
            builder: (_) => const VideoFramePreview(),
          ),
        ],
      ),
      LearnGroup(
        title: 'Failure Handling',
        scenarios: <LearnScenario>[
          LearnScenario(
            title: 'Retry',
            subtitle: 'Failure surface and exponential retry',
            icon: Icons.refresh_rounded,
            apiNote:
                'API: PixaFailure · PixaRetryPolicy.exponential · errorBuilder',
            builder: (_) => const RetryPreview(),
          ),
        ],
      ),
      LearnGroup(
        title: 'Advanced APIs',
        scenarios: <LearnScenario>[
          LearnScenario(
            title: 'Responsive image',
            subtitle: 'PixaSourceSet srcset selection by layout',
            icon: Icons.aspect_ratio_rounded,
            apiNote:
                'API: PixaResponsiveImage · PixaSourceSet · PixaSourceSetCandidate',
            builder: (_) => ResponsiveImagePreview(post: post),
          ),
          LearnScenario(
            title: 'Color analysis',
            subtitle: 'Runtime average/dominant/palette extraction',
            icon: Icons.palette_rounded,
            apiNote: 'API: Pixa.analyze() · PixaImageAnalysis',
            builder: (_) => ColorAnalysisPreview(post: post),
          ),
          LearnScenario(
            title: 'Cancellable load',
            subtitle: 'PixaPipelineHandle start and cancel',
            icon: Icons.cancel_schedule_send_rounded,
            apiNote:
                'API: Pixa.pipeline.startLoad() · PixaPipelineHandle.cancel()',
            builder: (_) => CancellableLoadPreview(post: post),
          ),
          LearnScenario(
            title: 'Warmup manifest',
            subtitle: 'Batch disk-cache warmup at startup',
            icon: Icons.local_fire_department_outlined,
            apiNote:
                'API: Pixa.warmup() · PixaCacheWarmupManifest · PixaCacheWarmupReport',
            builder: (_) => WarmupManifestPreview(post: post),
          ),
        ],
      ),
    ];
  }
}

class _LearnHeader extends StatelessWidget {
  const _LearnHeader({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: ShapeDecoration(
                  color: palette.accentSoft,
                  shape: const RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
                ),
                child: Icon(
                  Icons.menu_book_rounded,
                  color: palette.accent,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Learn Pixa',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$count production recipes covering every public capability of the Pixa pipeline.',
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const <Widget>[
              NeuStat(
                label: 'WIDGET',
                value: 'PixaImage',
                tone: NeuStatTone.accent,
              ),
              NeuStat(
                label: 'PROVIDER',
                value: 'ImageProvider',
                tone: NeuStatTone.accent,
              ),
              NeuStat(
                label: 'CACHE',
                value: 'multi-level',
                tone: NeuStatTone.accent,
              ),
              NeuStat(
                label: 'PROCESS',
                value: 'Rust',
                tone: NeuStatTone.accent,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A neumorphic search bar for filtering Learn scenarios by title, subtitle,
/// or API note. Shows the live result count.
class _LearnSearchBar extends StatelessWidget {
  const _LearnSearchBar({
    required this.query,
    required this.onChanged,
    required this.resultCount,
  });

  final String query;
  final ValueChanged<String> onChanged;
  final int resultCount;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: NeuCard(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
        child: Row(
          children: <Widget>[
            Icon(Icons.search_rounded, color: palette.textSecondary, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                onChanged: onChanged,
                style: TextStyle(color: palette.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search recipes…',
                  hintStyle: TextStyle(color: palette.textMuted, fontSize: 12),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            if (query.isNotEmpty)
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  onChanged('');
                },
                child: Icon(
                  Icons.clear_rounded,
                  color: palette.textMuted,
                  size: 16,
                ),
              )
            else
              Text(
                '$resultCount',
                style: TextStyle(
                  color: palette.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A horizontally-scrollable chip bar for quick navigation to any Learn
/// group. Each chip shows the group's icon and title; tapping scrolls to
/// that group (expanding it if collapsed).
class _QuickJumpBar extends StatelessWidget {
  const _QuickJumpBar({required this.groups, required this.onJump});

  final List<({String title, IconData icon})> groups;
  final void Function(String title) onJump;

  @override
  Widget build(BuildContext context) {
    final palette = context.neu;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: SizedBox(
        height: 38,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: groups.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (BuildContext context, int index) {
            final g = groups[index];
            return GestureDetector(
              onTap: () => onJump(g.title),
              child: NeuSurface(
                shape: NeuShape.convex,
                elevation: NeuElevation.low,
                borderRadius: BorderRadius.circular(14),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(g.icon, size: 14, color: palette.accent),
                    const SizedBox(width: 5),
                    Text(
                      g.title,
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.count,
    required this.collapsed,
    required this.onTap,
  });

  final String title;
  final int count;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Semantics(
        button: true,
        label:
            '$title, $count scenarios, ${collapsed ? "collapsed" : "expanded"}',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: Row(
            children: <Widget>[
              AnimatedRotation(
                turns: collapsed ? -0.25 : 0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                child: Icon(
                  Icons.chevron_right_rounded,
                  color: palette.accent,
                  size: 20,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: ShapeDecoration(
                  color: palette.accentSoft,
                  shape: const RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: palette.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScenarioCard extends StatefulWidget {
  const _ScenarioCard({required this.scenario});
  final LearnScenario scenario;

  @override
  State<_ScenarioCard> createState() => _ScenarioCardState();
}

class _ScenarioCardState extends State<_ScenarioCard> {
  /// Whether the heavy preview builder has been mounted. The card renders
  /// its header immediately (lightweight text + icon), then defers the
  /// PixaImage preview to the next frame so the first paint of the Learn
  /// page shows all card titles without waiting for image pipeline work.
  bool _previewReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _previewReady = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    final scenario = widget.scenario;
    return RepaintBoundary(
      child: Semantics(
        label: '${scenario.title}, ${scenario.subtitle}',
        container: true,
        child: NeuCard(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 38,
                    height: 38,
                    decoration: ShapeDecoration(
                      color: palette.accentSoft,
                      shape: const RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                      ),
                    ),
                    child: Icon(scenario.icon, color: palette.accent, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          scenario.title,
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          scenario.subtitle,
                          style: TextStyle(
                            color: palette.textMuted,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (_previewReady)
                scenario.builder(context)
              else
                SizedBox(
                  height: 200,
                  child: Center(child: NeuSpinner(size: 22)),
                ),
              if (scenario.apiNote.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                _ApiNote(text: scenario.apiNote),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact mono-style footnote that names the public API a recipe
/// demonstrates, so users can map a visible behaviour to the library surface.
class _ApiNote extends StatelessWidget {
  const _ApiNote({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 2, right: 6),
          child: Icon(
            Icons.code_rounded,
            size: 13,
            color: palette.accent.withValues(alpha: 0.8),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 11.5,
              height: 1.35,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }
}
