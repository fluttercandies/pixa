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
    : assert(itemCount > 0 && itemCount <= _dimensionDomain);

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
    final int dimensionIndex =
        (_seedOffset(seed) + index * _dimensionPermutationStep) %
        _dimensionDomain;
    final int width = _minimumDimension + dimensionIndex % _dimensionSpan;
    final int height = _minimumDimension + dimensionIndex ~/ _dimensionSpan;
    final int contentSeed = seed * 1000000 + index;
    final Uri uri = Uri.https(
      'picsum.photos',
      '/seed/pixa-$seed-${contentSeed.toRadixString(16)}'
          '/$width/$height',
    );
    return ProfileLiveNetworkSample(
      index: index,
      contentSeed: contentSeed,
      width: width,
      height: height,
      uri: uri,
    );
  }
}

const int _minimumDimension = 96;
const int _maximumDimension = 1024;
const int _dimensionSpan = _maximumDimension - _minimumDimension + 1;
const int _dimensionDomain = _dimensionSpan * _dimensionSpan;
const int _dimensionPermutationStep = 48271;

int _seedOffset(int seed) {
  return (seed * 1103515245 + 12345) % _dimensionDomain;
}
