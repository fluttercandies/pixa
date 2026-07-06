import '../models/image_post.dart';
import 'http_json.dart';
import 'image_source.dart';
import 'image_source_factory.dart';

/// konachan.net safe post source.
final class KonachanSource implements ImageSource {
  @override
  String get name => 'konachan';

  @override
  String get baseUrl => 'https://konachan.net';

  @override
  Future<List<ImagePost>> fetchPosts({
    required int page,
    required int limit,
  }) async {
    final Uri uri = Uri.parse(
      '$baseUrl/post.json?tags=rating:safe&limit=$limit&page=$page',
    );
    final Object? decoded = await fetchJson(uri);
    if (decoded is! List<Object?>) {
      throw const ImageSourceException('Invalid konachan response');
    }
    return <ImagePost>[
      for (final Object? item in decoded)
        if (item is Map<String, Object?>) _postFromItem(item),
    ];
  }

  ImagePost _postFromItem(Map<String, Object?> item) {
    final int id = item['id']! as int;
    final num width = (item['width'] ?? item['sample_width'])! as num;
    final num height = (item['height'] ?? item['sample_height'])! as num;
    return ImagePost(
      id: id,
      imageUrl: item['preview_url']! as String,
      width: width.toInt(),
      height: height.toInt(),
      source: SourceType.konachan,
    );
  }
}
