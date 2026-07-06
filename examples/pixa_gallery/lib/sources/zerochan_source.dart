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
    final int sourceWidth = ((item['width']! as num).toInt())
        .clamp(1, 1 << 30)
        .toInt();
    final int sourceHeight = ((item['height']! as num).toInt())
        .clamp(1, 1 << 30)
        .toInt();
    final String imageUrl = _jpegThumbnailUrl(item['thumbnail']! as String);
    final int width = _thumbnailWidth(imageUrl) ?? sourceWidth;
    final int height = (sourceHeight * width / sourceWidth)
        .round()
        .clamp(1, 1 << 30)
        .toInt();
    return ImagePost(
      id: item['id']! as int,
      imageUrl: imageUrl,
      width: width,
      height: height,
      source: SourceType.zerochan,
      thumbnailUrl: imageUrl,
      thumbnailWidth: width,
      thumbnailHeight: height,
    );
  }

  String _jpegThumbnailUrl(String thumbnailUrl) {
    final Uri uri = Uri.parse(thumbnailUrl);
    final int extensionStart = uri.path.lastIndexOf('.');
    if (extensionStart > 0) {
      return uri
          .replace(path: '${uri.path.substring(0, extensionStart)}.jpg')
          .toString();
    }
    return thumbnailUrl;
  }

  int? _thumbnailWidth(String imageUrl) {
    final List<String> segments = Uri.parse(imageUrl).pathSegments;
    for (final String segment in segments) {
      final int? width = int.tryParse(segment);
      if (width != null && width > 0) {
        return width;
      }
    }
    return null;
  }
}
