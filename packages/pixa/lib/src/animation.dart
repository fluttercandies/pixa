import 'package:flutter/foundation.dart';

/// Playback state for a Pixa animated image stream.
enum PixaAnimationPlaybackState {
  /// Frames are scheduled normally.
  playing,

  /// Current frame is retained and future frame emission is paused.
  paused,

  /// Frame scheduling is stopped until [PixaAnimationController.play].
  stopped,
}

/// Decoded-frame retention policy for controlled animation playback.
enum PixaAnimationFrameCachePolicy {
  /// Keep the already decoded next frame while paused.
  keepNextFrame,

  /// Release the decoded next frame when playback is paused or stopped.
  disposeNextFrameOnPause,
}

/// Disposal policy applied when controlled animation playback stops.
enum PixaAnimationDisposalPolicy {
  /// Keep the currently displayed frame alive through Flutter's image stream.
  keepCurrentFrame,

  /// Release decoded pending frames owned by Pixa's animation scheduler.
  disposeDecodedFrames,
}

/// Playback options for a controlled animated image stream.
@immutable
final class PixaAnimationOptions {
  /// Creates animation playback options.
  const PixaAnimationOptions({
    this.frameCachePolicy = PixaAnimationFrameCachePolicy.keepNextFrame,
    this.disposalPolicy = PixaAnimationDisposalPolicy.keepCurrentFrame,
  });

  /// How Pixa retains decoded next-frame data while paused.
  final PixaAnimationFrameCachePolicy frameCachePolicy;

  /// How Pixa releases scheduler-owned decoded frames on stop.
  final PixaAnimationDisposalPolicy disposalPolicy;

  @override
  bool operator ==(Object other) {
    return other is PixaAnimationOptions &&
        other.frameCachePolicy == frameCachePolicy &&
        other.disposalPolicy == disposalPolicy;
  }

  @override
  int get hashCode => Object.hash(frameCachePolicy, disposalPolicy);
}

/// Controls frame scheduling for one or more controlled animated image streams.
final class PixaAnimationController extends ChangeNotifier {
  /// Creates an animation controller.
  PixaAnimationController({
    PixaAnimationPlaybackState initialState =
        PixaAnimationPlaybackState.playing,
  }) : _state = initialState;

  PixaAnimationPlaybackState _state;
  bool _isDisposed = false;

  /// Current playback state.
  PixaAnimationPlaybackState get state => _state;

  /// Starts playback.
  void play() => _setState(PixaAnimationPlaybackState.playing);

  /// Pauses playback and keeps the currently displayed frame.
  void pause() => _setState(PixaAnimationPlaybackState.paused);

  /// Resumes playback after [pause].
  void resume() => play();

  /// Stops playback until [play] is called.
  void stop() => _setState(PixaAnimationPlaybackState.stopped);

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  void _setState(PixaAnimationPlaybackState state) {
    if (_isDisposed || _state == state) {
      return;
    }
    _state = state;
    notifyListeners();
  }
}
