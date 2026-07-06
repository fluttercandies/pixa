import '../models/image_post.dart';
import 'http_json.dart';
import 'image_source.dart';
import 'image_source_factory.dart';

/// zerochan.net popular safe thumbnail source.
final class ZerochanSource implements ImageSource {
  @override
  String get name => 'zerochan';

  @override
  String get baseUrl => 'https://www.zerochan.net';

  static const String _userAgent = 'Pixa Gallery Example - anonymous';

  @override
  Future<List<ImagePost>> fetchPosts({
    required int page,
    required int limit,
  }) async {
    final Uri uri = Uri.parse('$baseUrl/?p=$page&l=$limit&s=fav&t=1&json');
    final Object? decoded = await fetchJson(
      uri,
      headers: const <String, String>{'User-Agent': _userAgent},
    );
    if (decoded is! Map<String, Object?>) {
      throw const ImageSourceException('Invalid zerochan response');
    }
    final Object? items = decoded['items'];
    if (items is! List<Object?>) {
      return const <ImagePost>[];
    }
    return <ImagePost>[
      for (final Object? item in items)
        if (item is Map<String, Object?>) _postFromItem(item),
    ];
  }

  ImagePost _postFromItem(Map<String, Object?> item) {
    return ImagePost(
      id: item['id']! as int,
      imageUrl: item['thumbnail']! as String,
      width: (item['width']! as num).toInt(),
      height: (item['height']! as num).toInt(),
      source: SourceType.zerochan,
    );
  }
}
