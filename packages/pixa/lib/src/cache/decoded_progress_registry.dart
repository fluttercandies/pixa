import 'dart:async';
import 'dart:collection';

import '../progress.dart';

/// Weak fanout for listener-level progress on shared Flutter ImageCache keys.
final PixaDecodedProgressRegistry pixaDecodedProgressRegistry =
    PixaDecodedProgressRegistry();

/// Progress listener retained by its owning provider, not by the registry.
final class PixaDecodedProgressListener {
  /// Creates a weakly tracked progress listener.
  PixaDecodedProgressListener(this.callback);

  /// Consumer callback.
  final void Function(PixaProgress progress) callback;
}

/// Fans progress out without strongly retaining providers or callbacks.
final class PixaDecodedProgressRegistry {
  /// Creates a weak progress registry.
  PixaDecodedProgressRegistry() {
    _finalizer = Finalizer<_TrackedProgressListener>(_removeCollected);
  }

  late final Finalizer<_TrackedProgressListener> _finalizer;
  final Map<Object, LinkedHashSet<_TrackedProgressListener>> _listenersByKey =
      <Object, LinkedHashSet<_TrackedProgressListener>>{};

  /// Tracks one consumer for an equal decoded cache identity.
  void track({
    required Object key,
    required PixaDecodedProgressListener listener,
  }) {
    final LinkedHashSet<_TrackedProgressListener> listeners = _listenersByKey
        .putIfAbsent(key, LinkedHashSet<_TrackedProgressListener>.identity);
    for (final _TrackedProgressListener entry
        in List<_TrackedProgressListener>.of(listeners)) {
      final PixaDecodedProgressListener? existing = entry.listener.target;
      if (existing == null) {
        _remove(entry);
        continue;
      }
      if (identical(existing, listener)) {
        return;
      }
    }

    final _TrackedProgressListener entry = _TrackedProgressListener(
      key: key,
      listener: WeakReference<PixaDecodedProgressListener>(listener),
    );
    listeners.add(entry);
    _finalizer.attach(listener, entry, detach: entry);
  }

  /// Delivers progress to every live consumer sharing [key].
  void emit(Object key, PixaProgress progress) {
    final LinkedHashSet<_TrackedProgressListener>? listeners =
        _listenersByKey[key];
    if (listeners == null) {
      return;
    }
    for (final _TrackedProgressListener entry
        in List<_TrackedProgressListener>.of(listeners)) {
      final PixaDecodedProgressListener? listener = entry.listener.target;
      if (listener == null) {
        _remove(entry);
        continue;
      }
      try {
        listener.callback(progress);
      } on Object catch (error, stackTrace) {
        Zone.current.handleUncaughtError(error, stackTrace);
      }
    }
  }

  void _removeCollected(_TrackedProgressListener entry) {
    _remove(entry, detachFinalizer: false);
  }

  void _remove(_TrackedProgressListener entry, {bool detachFinalizer = true}) {
    final LinkedHashSet<_TrackedProgressListener>? listeners =
        _listenersByKey[entry.key];
    if (listeners == null || !listeners.remove(entry)) {
      return;
    }
    if (detachFinalizer) {
      _finalizer.detach(entry);
    }
    if (listeners.isEmpty) {
      _listenersByKey.remove(entry.key);
    }
  }
}

final class _TrackedProgressListener {
  const _TrackedProgressListener({required this.key, required this.listener});

  final Object key;
  final WeakReference<PixaDecodedProgressListener> listener;
}
