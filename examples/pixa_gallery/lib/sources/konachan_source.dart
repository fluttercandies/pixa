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
    final bool hasSample = item['sample_url'] != null;
    final String imageUrl =
        item['sample_url'] as String? ??
        item['jpeg_url'] as String? ??
        item['file_url'] as String? ??
        item['preview_url']! as String;
    final int width = (hasSample
        ? _intField(item, 'sample_width')
        : _intField(item, 'jpeg_width') ??
              _intField(item, 'width') ??
              _intField(item, 'preview_width'))!;
    final int height = (hasSample
        ? _intField(item, 'sample_height')
        : _intField(item, 'jpeg_height') ??
              _intField(item, 'height') ??
              _intField(item, 'preview_height'))!;
    return ImagePost(
      id: id,
      imageUrl: imageUrl,
      width: width,
      height: height,
      source: SourceType.konachan,
      thumbnailUrl: item['preview_url'] as String?,
      thumbnailWidth:
          _intField(item, 'actual_preview_width') ??
          _intField(item, 'preview_width'),
      thumbnailHeight:
          _intField(item, 'actual_preview_height') ??
          _intField(item, 'preview_height'),
    );
  }

  int? _intField(Map<String, Object?> item, String key) {
    final Object? value = item[key];
    return value is num ? value.toInt() : null;
  }
}
