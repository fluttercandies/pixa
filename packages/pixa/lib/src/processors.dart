/// Helpers for building stable runtime processor descriptors.
///
/// Pixa keeps processor descriptors as strings so cache keys remain compact and
/// stable across Dart and Rust. These helpers avoid typo-prone user code while
/// preserving the same runtime pipeline.
abstract final class PixaProcessors {
  /// Mirrors pixels horizontally.
  static String flipHorizontal() => 'flipHorizontal()';

  /// Mirrors pixels vertically.
  static String flipVertical() => 'flipVertical()';

  /// Converts pixels to grayscale.
  static String grayscale() => 'grayscale()';

  /// Inverts color channels while preserving alpha.
  static String invert() => 'invert()';

  /// Adds [value] to every color channel. Range: -255..255.
  static String brighten(int value) {
    RangeError.checkValueInInterval(value, -255, 255, 'value');
    return 'brighten(value=$value)';
  }

  /// Adjusts contrast by [value]. Range: -255..255.
  static String contrast(double value) {
    _checkFiniteRange(value, -255, 255, 'value');
    return 'contrast(value=${_formatDouble(value)})';
  }

  /// Rotates hue by [degrees]. Range: -360..360.
  static String hueRotate(int degrees) {
    RangeError.checkValueInInterval(degrees, -360, 360, 'degrees');
    return 'hueRotate(degrees=$degrees)';
  }

  static void _checkFiniteRange(
    double value,
    double min,
    double max,
    String name,
  ) {
    if (!value.isFinite || value < min || value > max) {
      throw RangeError.value(
        value,
        name,
        'must be finite and in range $min..$max',
      );
    }
  }

  static String _formatDouble(double value) {
    if (value == value.truncateToDouble()) {
      return value.toStringAsFixed(1);
    }
    return value.toString();
  }
}
