import '../models/image_post.dart';

/// Shared image gallery configuration.
final class ImageConfig {
  ImageConfig._();

  /// Current source selected by the sample app.
  static SourceType currentSource = SourceType.nekosia;

  /// Default page size used by the sample source.
  static const int defaultLimit = 48;
}
