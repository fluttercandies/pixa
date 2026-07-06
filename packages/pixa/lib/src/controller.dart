import 'package:flutter/foundation.dart';

import 'progress.dart';

/// Lifecycle controller for Pixa widgets.
final class PixaController extends ChangeNotifier {
  /// Creates a controller.
  PixaController();

  PixaLoadState _state = const PixaIdle();
  int _generation = 0;
  bool _attached = false;
  bool _visible = true;
  bool _isDisposed = false;

  /// Current load state.
  PixaLoadState get state => _state;

  /// Monotonic generation used to force provider reloads.
  int get generation => _generation;

  /// Whether a widget is attached.
  bool get isAttached => _attached;

  /// Whether the widget is visible.
  bool get isVisible => _visible;

  /// Marks the controller attached.
  void attach() {
    if (!_canMutate || _attached) {
      return;
    }
    _attached = true;
    notifyListeners();
  }

  /// Marks the controller detached.
  void detach() {
    if (!_canMutate || !_attached) {
      return;
    }
    _attached = false;
    notifyListeners();
  }

  /// Marks the image visible.
  void visible() {
    if (!_canMutate || _visible) {
      return;
    }
    _visible = true;
    notifyListeners();
  }

  /// Marks the image invisible.
  void invisible() {
    if (!_canMutate || !_visible) {
      return;
    }
    _visible = false;
    notifyListeners();
  }

  /// Requests a reload.
  void reload() {
    if (!_canMutate) {
      return;
    }
    _generation++;
    _state = const PixaLoading();
    notifyListeners();
  }

  /// Requests a retry.
  void retry() => reload();

  /// Cancels the current Dart listener lifecycle.
  void cancel() {
    if (!_canMutate) {
      return;
    }
    _state = const PixaCancelled();
    notifyListeners();
  }

  /// Pauses visible work.
  void pause() => invisible();

  /// Resumes visible work.
  void resume() => visible();

  /// Rebinds provider work after Flutter hot reload reassemble.
  void reassemble() {
    if (!_canMutate || !_attached) {
      return;
    }
    reload();
  }

  /// Updates state from widgets.
  void setState(PixaLoadState state) {
    if (!_canMutate) {
      return;
    }
    if (_isSameState(_state, state)) {
      return;
    }
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _attached = false;
    _visible = false;
    super.dispose();
  }

  bool get _canMutate => !_isDisposed;
}

bool _isSameState(PixaLoadState previous, PixaLoadState next) {
  if (previous.runtimeType != next.runtimeType) {
    return false;
  }
  return switch ((previous, next)) {
    (PixaLoading(progress: final a), PixaLoading(progress: final b)) =>
      _isSameProgress(a, b),
    _ => true,
  };
}

bool _isSameProgress(PixaProgress? previous, PixaProgress? next) {
  if (identical(previous, next)) {
    return true;
  }
  if (previous == null || next == null) {
    return false;
  }
  return previous.requestId == next.requestId &&
      previous.stage == next.stage &&
      previous.receivedBytes == next.receivedBytes &&
      previous.expectedBytes == next.expectedBytes &&
      previous.message == next.message &&
      _isSameProgressivePreview(
        previous.progressivePreview,
        next.progressivePreview,
      );
}

bool _isSameProgressivePreview(
  PixaProgressivePreview? previous,
  PixaProgressivePreview? next,
) {
  if (identical(previous, next)) {
    return true;
  }
  if (previous == null || next == null) {
    return false;
  }
  return previous.sequence == next.sequence &&
      previous.mimeType == next.mimeType &&
      identical(previous.bytes, next.bytes);
}
