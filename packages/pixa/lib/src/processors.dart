/// Resize behavior for [PixaProcessors.resize].
enum PixaResizeMode {
  /// Preserve aspect ratio and fit within the supplied bounds.
  fit,

  /// Force the exact supplied output dimensions.
  exact,
}

/// Resize sampling filter for runtime processors.
enum PixaResizeFilter {
  /// Nearest-neighbor sampling.
  nearest,

  /// Triangle/linear sampling.
  triangle,

  /// Catmull-Rom/cubic sampling.
  catmullRom,

  /// Gaussian sampling.
  gaussian,

  /// Lanczos3 sampling.
  lanczos3,
}

/// Helpers for building stable runtime processor descriptors.
///
/// Pixa keeps processor descriptors as strings so cache keys remain compact and
/// stable across Dart and Rust. These helpers avoid typo-prone user code while
/// preserving the same runtime pipeline.
abstract final class PixaProcessors {
  /// Resizes an image. At least one of [width] or [height] is required.
  static String resize({
    int? width,
    int? height,
    PixaResizeMode mode = PixaResizeMode.fit,
    PixaResizeFilter filter = PixaResizeFilter.lanczos3,
  }) {
    if (width == null && height == null) {
      throw ArgumentError('resize requires width or height.');
    }
    final List<String> args = <String>[];
    if (width != null) {
      args.add('width=${_checkPositiveInt(width, 'width')}');
    }
    if (height != null) {
      args.add('height=${_checkPositiveInt(height, 'height')}');
    }
    args.add('mode=${_resizeMode(mode)}');
    args.add('filter=${_resizeFilter(filter)}');
    return 'resize(${args.join(',')})';
  }

  /// Resizes an image to an exact [width] and [height].
  static String resizeExact(
    int width,
    int height, {
    PixaResizeFilter filter = PixaResizeFilter.lanczos3,
  }) {
    return 'resizeExact(width=${_checkPositiveInt(width, 'width')},'
        'height=${_checkPositiveInt(height, 'height')},'
        'filter=${_resizeFilter(filter)})';
  }

  /// Crops a rectangle from the image.
  static String crop({
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    return 'crop(x=${_checkNonNegativeInt(x, 'x')},'
        'y=${_checkNonNegativeInt(y, 'y')},'
        'width=${_checkPositiveInt(width, 'width')},'
        'height=${_checkPositiveInt(height, 'height')})';
  }

  /// Crops a source tile and resizes it to decoded tile dimensions.
  static String tileCropResize({
    required int x,
    required int y,
    required int width,
    required int height,
    required int decodedWidth,
    required int decodedHeight,
    int sampleSize = 1,
    PixaResizeFilter filter = PixaResizeFilter.lanczos3,
  }) {
    return 'tile(x=${_checkNonNegativeInt(x, 'x')},'
        'y=${_checkNonNegativeInt(y, 'y')},'
        'width=${_checkPositiveInt(width, 'width')},'
        'height=${_checkPositiveInt(height, 'height')},'
        'decodedWidth=${_checkPositiveInt(decodedWidth, 'decodedWidth')},'
        'decodedHeight=${_checkPositiveInt(decodedHeight, 'decodedHeight')},'
        'sampleSize=${_checkPositiveInt(sampleSize, 'sampleSize')},'
        'filter=${_resizeFilter(filter)})';
  }

  /// Rotates by 0, 90, 180, or 270 degrees.
  static String rotate(int degrees) {
    if (degrees != 0 && degrees != 90 && degrees != 180 && degrees != 270) {
      throw ArgumentError.value(
        degrees,
        'degrees',
        'must be one of 0, 90, 180, or 270',
      );
    }
    return 'rotate(degrees=$degrees)';
  }

  /// Applies a Gaussian blur. Range: 0..128.
  static String blur(double sigma) {
    _checkFiniteRange(sigma, 0, 128, 'sigma');
    return 'blur(sigma=${_formatDouble(sigma)})';
  }

  /// Applies a faster approximate Gaussian blur. Range: 0..128.
  static String fastBlur(double sigma) {
    _checkFiniteRange(sigma, 0, 128, 'sigma');
    return 'fastBlur(sigma=${_formatDouble(sigma)})';
  }

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

  /// Applies an unsharp mask. [sigma] range: 0..128, [threshold] range: 0..255.
  static String unsharpen({required double sigma, required int threshold}) {
    _checkFiniteRange(sigma, 0, 128, 'sigma');
    RangeError.checkValueInInterval(threshold, 0, 255, 'threshold');
    return 'unsharpen(sigma=${_formatDouble(sigma)},threshold=$threshold)';
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

  static int _checkPositiveInt(int value, String name) {
    if (value <= 0) {
      throw RangeError.value(value, name, 'must be greater than zero');
    }
    return value;
  }

  static int _checkNonNegativeInt(int value, String name) {
    if (value < 0) {
      throw RangeError.value(
        value,
        name,
        'must be greater than or equal to zero',
      );
    }
    return value;
  }

  static String _resizeMode(PixaResizeMode mode) {
    return switch (mode) {
      PixaResizeMode.fit => 'fit',
      PixaResizeMode.exact => 'exact',
    };
  }

  static String _resizeFilter(PixaResizeFilter filter) {
    return switch (filter) {
      PixaResizeFilter.nearest => 'nearest',
      PixaResizeFilter.triangle => 'triangle',
      PixaResizeFilter.catmullRom => 'catmullrom',
      PixaResizeFilter.gaussian => 'gaussian',
      PixaResizeFilter.lanczos3 => 'lanczos3',
    };
  }
}
