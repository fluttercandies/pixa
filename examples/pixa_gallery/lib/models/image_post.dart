/// Image source tabs retained from the gallery reference implementation.
enum SourceType {
  /// yande.re safe post source.
  yande,

  /// zerochan.net popular thumbnail source.
  zerochan,

  /// nekosia.cat random safe image source.
  nekosia,

  /// konachan.net safe post source.
  konachan,
}

/// Image metadata used by the gallery layout and Pixa request layer.
final class ImagePost {
  /// Creates one image post.
  const ImagePost({
    required this.id,
    required this.imageUrl,
    required this.width,
    required this.height,
    required this.source,
    this.thumbnailUrl,
    this.thumbnailWidth,
    this.thumbnailHeight,
  });

  /// Stable image identifier.
  final int id;

  /// Full image URL.
  final String imageUrl;

  /// Source image width.
  final int width;

  /// Source image height.
  final int height;

  /// Image source bucket.
  final SourceType source;

  /// Optional lightweight preview URL with dimensions that match the payload.
  final String? thumbnailUrl;

  /// Preview width in pixels.
  final int? thumbnailWidth;

  /// Preview height in pixels.
  final int? thumbnailHeight;

  /// Runtime aspect ratio used by the row layout.
  double get aspectRatio => width > 0 && height > 0 ? width / height : 1;

  /// Low-resolution URL for placeholder-to-full swaps.
  String lowResUrl({int size = 96}) {
    return thumbnailUrl ?? imageUrl;
  }

  @override
  String toString() {
    return 'ImagePost(id: $id, width: $width, height: $height, '
        'source: ${source.name})';
  }
}
