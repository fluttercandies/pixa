import 'dart:math' as math;

import '../models/image_post.dart';
import 'http_json.dart';
import 'image_source.dart';
import 'image_source_factory.dart';

/// nekosia.cat random safe image source.
final class NekosiaSource implements ImageSource {
  @override
  String get name => 'nekosia';

  @override
  String get baseUrl => 'https://api.nekosia.cat/api/v1';

  static final String _session = DateTime.now().microsecondsSinceEpoch
      .toRadixString(36);

  static const List<String> _categories = <String>[
    'random',
    'catgirl',
    'foxgirl',
    'wolfgirl',
    'animal-ears',
    'cute',
    'girl',
    'maid',
    'vtuber',
    'wink',
    'headphones',
    'uniform',
    'ribbon',
    'blue-hair',
    'long-hair',
  ];

  @override
  Future<List<ImagePost>> fetchPosts({
    required int page,
    required int limit,
  }) async {
    final int count = limit.clamp(1, 20);
    final String category = _categories[(page - 1).abs() % _categories.length];
    final Uri uri = Uri.parse(
      '$baseUrl/images/$category?count=$count&rating=safe&session=$_session',
    );
    final Object? decoded = await fetchJson(uri);
    if (decoded is! Map<String, Object?>) {
      throw const ImageSourceException('Invalid nekosia response');
    }
    final Object? images = decoded['images'];
    if (images is! List<Object?>) {
      return const <ImagePost>[];
    }
    return <ImagePost>[
      for (final Object? item in images)
        if (item is Map<String, Object?>) _postFromItem(item),
    ];
  }

  ImagePost _postFromItem(Map<String, Object?> item) {
    final Map<String, Object?> image = item['image']! as Map<String, Object?>;
    final Map<String, Object?> compressed =
        image['compressed']! as Map<String, Object?>;
    final Map<String, Object?> metadata =
        item['metadata']! as Map<String, Object?>;
    final Map<String, Object?> meta =
        (metadata['compressed'] ?? metadata['original'])!
            as Map<String, Object?>;
    final String id =
        item['id'] as String? ??
        DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return ImagePost(
      id: _stringIdToInt(id),
      imageUrl: compressed['url']! as String,
      width: (meta['width']! as num).toInt(),
      height: (meta['height']! as num).toInt(),
      source: SourceType.nekosia,
    );
  }

  int _stringIdToInt(String id) {
    var hash = 0;
    for (var index = 0; index < id.length; index++) {
      hash = (hash << 5) - hash + id.codeUnitAt(index);
      hash = hash & 0x3fffffff;
    }
    return math.max(1, hash.abs());
  }
}
