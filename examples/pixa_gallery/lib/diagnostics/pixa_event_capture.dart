import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:pixa/pixa.dart';

/// A bounded, app-scoped capture of recent [PixaEvent]s emitted by the
/// pipeline observer bus.
///
/// Registered once during `Pixa.configure` (see `main.dart`) so every load,
/// cache hit/miss, decode and failure that flows through the runtime is
/// mirrored here. The Learn "Observer events" scenario and the Runtime tab
/// read the latest window to visualise the live event stream — this is the
/// same observability surface `PixaConfig(observers:)` exposes to host apps.
class PixaEventCapture extends ChangeNotifier implements PixaObserver {
  PixaEventCapture._();

  /// Singleton instance installed at app startup.
  static final PixaEventCapture instance = PixaEventCapture._();

  /// Maximum number of events retained in the rolling window.
  static const int capacity = 60;

  final List<PixaEvent> _events = <PixaEvent>[];

  /// The most recent events, newest last.
  List<PixaEvent> get events => List<PixaEvent>.unmodifiable(_events);

  /// Total events observed since startup.
  int get total => _total;
  int _total = 0;

  @override
  void onPixaEvent(PixaEvent event) {
    _total += 1;
    if (_events.length >= capacity) {
      _events.removeAt(0);
    }
    _events.add(event);
    // Use SchedulerBinding.addPostFrameCallback instead of scheduleMicrotask
    // to avoid flooding the microtask queue on merged-thread platforms
    // (macOS with experimental merged UI/platform thread), which can cause
    // the frame loop to starve and the UI to freeze.
    if (!_pendingNotify) {
      _pendingNotify = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _pendingNotify = false;
        notifyListeners();
      });
    }
  }

  bool _pendingNotify = false;
}

/// A [PixaObserver] that forwards to [PixaEventCapture.instance], so the app
/// can be configured with `observers: [appEventObserver]` at startup.
final PixaObserver appEventObserver = PixaEventCapture.instance;
