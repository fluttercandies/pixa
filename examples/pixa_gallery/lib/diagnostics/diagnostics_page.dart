import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';

import '../pixa/pixa_recipes.dart';
import '../theme/neu_palette.dart';
import '../widgets/neu_controls.dart';
import 'pixa_event_capture.dart';

/// The Diagnostics page: live runtime, cache, scheduler and format state
/// plus cache / memory operations.
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key, this.initialAutoRefresh});

  /// Initial value for the auto-refresh toggle. When provided the toggle
  /// also stays in sync with this value (used by the central Settings page).
  final bool? initialAutoRefresh;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  PixaDebugSnapshot _snapshot = PixaDebugInspector.snapshot();
  String _status = 'Live';
  Timer? _pollTimer;
  bool _autoRefresh = true;

  @override
  void initState() {
    super.initState();
    _autoRefresh = widget.initialAutoRefresh ?? true;
    PixaEventCapture.instance.addListener(_onObserverEvent);
    _startPolling();
  }

  @override
  void didUpdateWidget(covariant DiagnosticsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialAutoRefresh != null &&
        widget.initialAutoRefresh != oldWidget.initialAutoRefresh &&
        widget.initialAutoRefresh != _autoRefresh) {
      _autoRefresh = widget.initialAutoRefresh!;
      _status = _autoRefresh ? 'Live' : 'Paused';
      if (_autoRefresh) {
        _startPolling();
      } else {
        _pollTimer?.cancel();
      }
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    PixaEventCapture.instance.removeListener(_onObserverEvent);
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    if (_autoRefresh) {
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (mounted) {
          _refresh();
        }
      });
    }
  }

  void _toggleAutoRefresh() {
    HapticFeedback.selectionClick();
    setState(() {
      _autoRefresh = !_autoRefresh;
      _status = _autoRefresh ? 'Live' : 'Paused';
    });
    if (_autoRefresh) {
      _startPolling();
    } else {
      _pollTimer?.cancel();
    }
  }

  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  void _onObserverEvent() {
    if (mounted && _autoRefresh) {
      // Throttle: don't refresh more than once per second to avoid
      // frame starvation on merged-thread platforms (macOS).
      final now = DateTime.now();
      if (now.difference(_lastRefresh).inMilliseconds >= 1000) {
        _lastRefresh = now;
        _refresh();
      }
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _snapshot = PixaDebugInspector.snapshot();
      _status = _autoRefresh ? 'Live' : 'Refreshed';
    });
  }

  /// Builds up to 6 rows from the most recent observer events (newest first).
  List<_DiagRow> _recentObserverRows() {
    final events = PixaEventCapture.instance.events;
    if (events.isEmpty) {
      return const <_DiagRow>[_DiagRow('Latest', 'none yet')];
    }
    final start = events.length - 1;
    final count = start < 6 ? start + 1 : 6;
    return <_DiagRow>[
      for (var i = 0; i < count; i++)
        _DiagRow(
          events[start - i].stage.name,
          '${events[start - i].name} · #${events[start - i].requestId}',
        ),
    ];
  }

  Future<void> _trim() async {
    await Pixa.trimMemory(level: PixaMemoryTrimLevel.critical);
    await _refresh();
    if (mounted) {
      setState(() => _status = 'Memory trimmed');
    }
  }

  Future<void> _clearEncoded() async {
    await Pixa.clearCache(decoded: false);
    await _refresh();
    if (mounted) {
      setState(() => _status = 'Encoded cache cleared');
    }
  }

  Future<void> _clearDecoded() async {
    await Pixa.clearCache(encoded: false);
    await _refresh();
    if (mounted) {
      setState(() => _status = 'Decoded cache cleared');
    }
  }

  /// Exports a full diagnostic snapshot as a formatted JSON string, copies it
  /// to the clipboard so it can be pasted into a bug report or support chat.
  Future<void> _exportSnapshot() async {
    HapticFeedback.selectionClick();
    final snap = PixaDebugInspector.snapshot();
    final cache = snap.cacheStats;
    final decoded = snap.decodedCacheStats;
    final scheduler = snap.schedulerStats;
    final json = const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'pixaVersion': Pixa.version,
      'platform': snap.capabilities.platformStatus.platform,
      'runtimeAvailable': snap.capabilities.platformStatus.runtimeAvailable,
      'selfCheckPassed': snap.platformSelfCheck.passed,
      'config': <String, Object?>{
        'memoryCacheBytes': Pixa.config.memoryCacheBytes,
        'diskCacheBytes': Pixa.config.diskCacheBytes,
        'networkConcurrency': Pixa.config.networkConcurrency,
        'decodeConcurrency': Pixa.config.decodeConcurrency,
        'maxImageCompletionsPerFrame': Pixa.config.maxImageCompletionsPerFrame,
        'maxQueuedRuntimeLoads': Pixa.config.maxQueuedRuntimeLoads,
        'maxQueuedDecodes': Pixa.config.maxQueuedDecodes,
      },
      'cacheStats': cache == null
          ? null
          : <String, Object?>{
              'memoryBytes': cache.memoryBytes,
              'memoryEntries': cache.memoryEntries,
              'hitRate': cache.hitRate,
              'diskWrites': cache.diskWrites,
              'diskCorruptionRecoveries': cache.diskCorruptionRecoveries,
              'evictions': cache.evictions,
              'processedHitRate': cache.processedHitRate,
              'liveOwnedBufferHandles': cache.liveOwnedBufferHandles,
            },
      'decodedCacheStats': <String, Object?>{
        'currentSize': decoded.currentSize,
        'maximumSize': decoded.maximumSize,
        'currentSizeBytes': decoded.currentSizeBytes,
        'maximumSizeBytes': decoded.maximumSizeBytes,
        'liveImageCount': decoded.liveImageCount,
        'byteUtilization': decoded.byteUtilization,
      },
      'schedulerStats': scheduler == null
          ? null
          : <String, Object?>{
              'activeRuntimeLoads': scheduler.activeRuntimeLoads,
              'queueDepth': scheduler.queueDepth,
              'inflightRequests': scheduler.inflightRequests,
              'listeners': scheduler.listeners,
              'totalCoalesced': scheduler.totalCoalesced,
              'totalBackpressureDropped': scheduler.totalBackpressureDropped,
            },
      'observerEventsObserved': PixaEventCapture.instance.total,
    });
    await Clipboard.setData(ClipboardData(text: json));
    if (mounted) {
      setState(() => _status = 'Snapshot copied (${json.length} bytes)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final PixaCacheStats? cache = _snapshot.cacheStats;
    final PixaDecodedCacheStats decoded = _snapshot.decodedCacheStats;
    final PixaSchedulerStats? scheduler = _snapshot.schedulerStats;
    final List<PixaRuntimeImageFormatCapability> formats =
        _snapshot.capabilities.imageFormats;
    final List<String> runtimeFormats = formats
        .where((PixaRuntimeImageFormatCapability f) => f.defaultRuntimeDisplay)
        .map((PixaRuntimeImageFormatCapability f) => f.format.name)
        .toList();

    return SafeArea(
      bottom: false,
      child: ListView(
        key: const ValueKey<String>('pixa-diagnostics-scroll'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          _Header(
            status: _status,
            onRefresh: _refresh,
            autoRefresh: _autoRefresh,
            onToggleAutoRefresh: _toggleAutoRefresh,
          ),
          const SizedBox(height: 14),
          _ActionsRow(
            onTrim: _trim,
            onClearEncoded: _clearEncoded,
            onClearDecoded: _clearDecoded,
            onExport: _exportSnapshot,
          ),
          const SizedBox(height: 14),
          _DiagCard(
            title: 'Runtime',
            icon: Icons.memory_rounded,
            rows: <_DiagRow>[
              _DiagRow(
                'Platform',
                _snapshot.capabilities.platformStatus.platform,
              ),
              _DiagRow(
                'Runtime',
                _snapshot.capabilities.platformStatus.runtimeAvailable
                    ? 'available'
                    : 'unavailable',
              ),
              _DiagRow(
                'Self-check',
                _snapshot.platformSelfCheck.passed ? 'passed' : 'failed',
              ),
              _DiagRow(
                'HTTP transport',
                _snapshot.capabilities.httpTransport ? 'enabled' : 'disabled',
              ),
              _DiagRow(
                'Disk cache',
                _snapshot.capabilities.diskCache ? 'enabled' : 'disabled',
              ),
              _DiagRow(
                'Pixel processors',
                _snapshot.capabilities.pixelProcessors ? 'enabled' : 'disabled',
              ),
            ],
          ),
          const SizedBox(height: 14),
          _DiagCard(
            title: 'Cache',
            icon: Icons.storage_rounded,
            rows: <_DiagRow>[
              _DiagRow('Encoded memory', formatBytes(cache?.memoryBytes ?? 0)),
              _DiagRow('Memory entries', '${cache?.memoryEntries ?? 0}'),
              _DiagRow(
                'Hit rate',
                '${((cache?.hitRate ?? 0) * 100).toStringAsFixed(1)}%',
              ),
              _DiagRow('Disk writes', '${cache?.diskWrites ?? 0}'),
              _DiagRow(
                'Processed hit rate',
                '${((cache?.processedHitRate ?? 0) * 100).toStringAsFixed(1)}%',
              ),
              _DiagRow('Live buffers', '${cache?.liveOwnedBufferHandles ?? 0}'),
            ],
          ),
          const SizedBox(height: 14),
          _DiagCard(
            title: 'Decoded ImageCache',
            icon: Icons.image_rounded,
            rows: <_DiagRow>[
              _DiagRow(
                'Entries',
                '${decoded.currentSize}/${decoded.maximumSize}',
              ),
              _DiagRow(
                'Bytes',
                '${formatBytes(decoded.currentSizeBytes)} / '
                    '${formatBytes(decoded.maximumSizeBytes)}',
              ),
              _DiagRow('Live images', '${decoded.liveImageCount}'),
              _DiagRow(
                'Utilization',
                '${(decoded.byteUtilization * 100).clamp(0, 999).toStringAsFixed(1)}%',
              ),
            ],
          ),
          const SizedBox(height: 14),
          _DiagCard(
            title: 'Scheduler',
            icon: Icons.schedule_rounded,
            rows: <_DiagRow>[
              _DiagRow(
                'Active runtime loads',
                '${scheduler?.activeRuntimeLoads ?? 0}',
              ),
              _DiagRow('Queue depth', '${scheduler?.queueDepth ?? 0}'),
              _DiagRow(
                'In-flight requests',
                '${scheduler?.inflightRequests ?? 0}',
              ),
              _DiagRow('Listeners', '${scheduler?.listeners ?? 0}'),
              _DiagRow('Coalesced', '${scheduler?.totalCoalesced ?? 0}'),
              _DiagRow(
                'Backpressure dropped',
                '${scheduler?.totalBackpressureDropped ?? 0}',
              ),
            ],
          ),
          const SizedBox(height: 14),
          _DiagCard(
            title: 'Observer events',
            icon: Icons.stream_rounded,
            rows: <_DiagRow>[
              _DiagRow('Total observed', '${PixaEventCapture.instance.total}'),
              _DiagRow(
                'Window size',
                '${PixaEventCapture.instance.events.length}/'
                    '${PixaEventCapture.capacity}',
              ),
              ..._recentObserverRows(),
            ],
          ),
          const SizedBox(height: 14),
          _DiagCard(
            title: 'Formats and plugins',
            icon: Icons.extension_rounded,
            rows: <_DiagRow>[
              _DiagRow('Image formats', '${formats.length}'),
              _DiagRow('Runtime formats', runtimeFormats.take(14).join(', ')),
              _DiagRow(
                'Region decode formats',
                formats
                    .where(
                      (PixaRuntimeImageFormatCapability f) => f.regionDecode,
                    )
                    .map((PixaRuntimeImageFormatCapability f) => f.format.name)
                    .join(', '),
              ),
              _DiagRow(
                'Video-frame backends',
                '${_snapshot.registryArchitecture.videoFrameBackends}',
              ),
              _DiagRow(
                'Runtime video routes',
                _snapshot
                        .capabilities
                        .runtimePluginRegistryStats
                        .videoFrameSourceKinds
                        .isEmpty
                    ? 'none'
                    : _snapshot
                          .capabilities
                          .runtimePluginRegistryStats
                          .videoFrameSourceKinds
                          .join(', '),
              ),
              _DiagRow(
                'Runtime modules',
                '${_snapshot.registryArchitecture.runtimeModules}',
              ),
              _DiagRow(
                'Single host binary',
                _snapshot.registryArchitecture.runtimeCanUseSingleHostBinary
                    ? 'yes'
                    : 'no',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.status,
    required this.onRefresh,
    this.autoRefresh = true,
    this.onToggleAutoRefresh,
  });
  final String status;
  final VoidCallback onRefresh;
  final bool autoRefresh;
  final VoidCallback? onToggleAutoRefresh;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
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
          child: Icon(
            Icons.monitor_heart_rounded,
            color: palette.accent,
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Runtime Console',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: <Widget>[
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: autoRefresh ? palette.success : palette.textMuted,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    status,
                    style: TextStyle(color: palette.textMuted, fontSize: 12.5),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (onToggleAutoRefresh != null)
          NeuIconButton(
            icon: autoRefresh
                ? Icons.pause_circle_rounded
                : Icons.play_circle_rounded,
            tooltip: autoRefresh ? 'Pause live updates' : 'Resume live updates',
            size: 42,
            iconSize: 20,
            selected: autoRefresh,
            onPressed: onToggleAutoRefresh,
          ),
        NeuIconButton(
          icon: Icons.refresh_rounded,
          tooltip: 'Refresh',
          size: 46,
          iconSize: 20,
          onPressed: onRefresh,
        ),
      ],
    );
  }
}

class _ActionsRow extends StatelessWidget {
  const _ActionsRow({
    required this.onTrim,
    required this.onClearEncoded,
    required this.onClearDecoded,
    required this.onExport,
  });

  final VoidCallback onTrim;
  final VoidCallback onClearEncoded;
  final VoidCallback onClearDecoded;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        NeuButton(
          onPressed: onTrim,
          accent: true,
          icon: const Icon(Icons.compress_rounded),
          child: const Text('Trim memory'),
        ),
        NeuButton(
          onPressed: onClearEncoded,
          icon: const Icon(Icons.cleaning_services_outlined),
          child: const Text('Clear encoded'),
        ),
        NeuButton(
          onPressed: onClearDecoded,
          icon: const Icon(Icons.layers_clear_rounded),
          child: const Text('Clear decoded'),
        ),
        NeuButton(
          onPressed: onExport,
          icon: const Icon(Icons.ios_share_rounded),
          child: const Text('Export'),
        ),
      ],
    );
  }
}

class _DiagRow {
  const _DiagRow(this.label, this.value);
  final String label;
  final String value;
}

class _DiagCard extends StatelessWidget {
  const _DiagCard({
    required this.title,
    required this.icon,
    required this.rows,
  });

  final String title;
  final IconData icon;
  final List<_DiagRow> rows;

  @override
  Widget build(BuildContext context) {
    final NeuPalette palette = context.neu;
    return NeuCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, color: palette.accent, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final _DiagRow row in rows) ...<Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      row.label,
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Flexible(
                    child: Text(
                      row.value,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
