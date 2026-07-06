import '../models/image_post.dart';
import 'image_source.dart';
import 'konachan_source.dart';
import 'nekosia_source.dart';
import 'yande_source.dart';
import 'zerochan_source.dart';

/// Creates the selected example image source.
final class ImageSourceFactory {
  ImageSourceFactory._();

  /// Builds a source for [type].
  static ImageSource create(SourceType type) {
    return switch (type) {
      SourceType.yande => YandeSource(),
      SourceType.zerochan => ZerochanSource(),
      SourceType.nekosia => NekosiaSource(),
      SourceType.konachan => KonachanSource(),
    };
  }
}

/// Error thrown by example metadata sources.
final class ImageSourceException implements Exception {
  /// Creates a source exception.
  const ImageSourceException(this.message);

  /// Safe error message.
  final String message;

  @override
  String toString() => message;
}
