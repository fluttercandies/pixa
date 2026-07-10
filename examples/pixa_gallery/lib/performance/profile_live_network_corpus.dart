/// One deterministic image in the supplemental Picsum profile corpus.
final class ProfileLiveNetworkSample {
  const ProfileLiveNetworkSample({
    required this.index,
    required this.contentSeed,
    required this.width,
    required this.height,
    required this.uri,
  });

  final int index;
  final int contentSeed;
  final int width;
  final int height;
  final Uri uri;

  ({int width, int height}) get size => (width: width, height: height);

  @override
  bool operator ==(Object other) {
    return other is ProfileLiveNetworkSample &&
        other.index == index &&
        other.contentSeed == contentSeed &&
        other.width == width &&
        other.height == height &&
        other.uri == uri;
  }

  @override
  int get hashCode => Object.hash(index, contentSeed, width, height, uri);
}

/// Reproducible, size-varied Picsum corpus for supplemental live-network runs.
final class ProfileLiveNetworkCorpus {
  const ProfileLiveNetworkCorpus({required this.seed, required this.itemCount})
    : assert(itemCount > 0);

  final int seed;
  final int itemCount;

  List<ProfileLiveNetworkSample> get samples {
    return List<ProfileLiveNetworkSample>.unmodifiable(
      List<ProfileLiveNetworkSample>.generate(itemCount, sampleAt),
    );
  }

  ProfileLiveNetworkSample sampleAt(int index) {
    if (index < 0 || index >= itemCount) {
      throw RangeError.index(index, this, 'index', null, itemCount);
    }
    final int sizeIndex = (index * 7 + seed.abs()) % _sizes.length;
    final ({int width, int height}) size = _sizes[sizeIndex];
    final int contentSeed = seed * 1000000 + index;
    final Uri uri = Uri.https(
      'picsum.photos',
      '/seed/pixa-$seed-${contentSeed.toRadixString(16)}'
          '/${size.width}/${size.height}',
    );
    return ProfileLiveNetworkSample(
      index: index,
      contentSeed: contentSeed,
      width: size.width,
      height: size.height,
      uri: uri,
    );
  }
}

const List<({int width, int height})> _sizes = <({int width, int height})>[
  (width: 96, height: 96),
  (width: 128, height: 192),
  (width: 192, height: 128),
  (width: 240, height: 320),
  (width: 320, height: 240),
  (width: 320, height: 320),
  (width: 480, height: 270),
  (width: 270, height: 480),
  (width: 640, height: 480),
  (width: 1024, height: 576),
];
