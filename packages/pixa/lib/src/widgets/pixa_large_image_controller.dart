part of 'pixa_large_image.dart';

/// Controller for a [PixaLargeImage].
final class PixaLargeImageController extends ChangeNotifier {
  /// Creates a large image controller.
  PixaLargeImageController() {
    _transform.addListener(notifyListeners);
  }

  final TransformationController _transform = TransformationController();

  VoidCallback? _resetHandler;
  void Function(double scale, Offset? focalPoint)? _zoomToHandler;

  /// Current transformation matrix.
  Matrix4 get value => _transform.value;

  /// Current scene scale.
  double get scale => pixaLargeImageTransformScale(_transform.value);

  /// Sets the transformation matrix.
  set value(Matrix4 value) {
    _transform.value = value;
  }

  /// Resets the viewport to the configured initial fit.
  void reset() {
    _resetHandler?.call();
  }

  /// Zooms around [focalPoint] in the viewport, or around the viewport center.
  void zoomTo(double scale, {Offset? focalPoint}) {
    _zoomToHandler?.call(scale, focalPoint);
  }

  @override
  void dispose() {
    _transform.removeListener(notifyListeners);
    _transform.dispose();
    super.dispose();
  }
}
