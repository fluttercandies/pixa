import '../models/image_post.dart';

/// Image post source used by the example gallery.
abstract interface class ImageSource {
  /// Human-readable source name.
  String get name;

  /// Source base URL or origin label.
  String get baseUrl;

  /// Fetches one page of image posts.
  Future<List<ImagePost>> fetchPosts({required int page, required int limit});
}
