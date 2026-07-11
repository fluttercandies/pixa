import 'package:flutter_test/flutter_test.dart';
import 'package:pixa_gallery/performance/profile_live_network_corpus.dart';

void main() {
  test('Picsum corpus is seeded, varied, and reproducible', () {
    const ProfileLiveNetworkCorpus first = ProfileLiveNetworkCorpus(
      seed: 20260710,
      itemCount: 240,
    );
    const ProfileLiveNetworkCorpus second = ProfileLiveNetworkCorpus(
      seed: 20260710,
      itemCount: 240,
    );

    final List<ProfileLiveNetworkSample> firstSamples = first.samples;
    final List<ProfileLiveNetworkSample> secondSamples = second.samples;

    expect(firstSamples, secondSamples);
    expect(firstSamples, hasLength(240));
    expect(
      firstSamples.map((ProfileLiveNetworkSample sample) => sample.uri).toSet(),
      hasLength(240),
    );
    expect(
      firstSamples
          .map((ProfileLiveNetworkSample sample) => sample.size)
          .toSet(),
      hasLength(240),
    );
    expect(
      firstSamples.any(
        (ProfileLiveNetworkSample sample) => sample.width > sample.height,
      ),
      isTrue,
    );
    expect(
      firstSamples.any(
        (ProfileLiveNetworkSample sample) => sample.height > sample.width,
      ),
      isTrue,
    );
    for (final ProfileLiveNetworkSample sample in firstSamples) {
      expect(sample.uri.scheme, 'https');
      expect(sample.uri.host, 'picsum.photos');
      expect(sample.uri.path, contains('/seed/pixa-20260710-'));
      expect(sample.width, inInclusiveRange(96, 1024));
      expect(sample.height, inInclusiveRange(96, 1024));
    }
  });

  test('changing the seed changes content and dimension sequences', () {
    const ProfileLiveNetworkCorpus first = ProfileLiveNetworkCorpus(
      seed: 20260710,
      itemCount: 240,
    );
    const ProfileLiveNetworkCorpus second = ProfileLiveNetworkCorpus(
      seed: 20260711,
      itemCount: 240,
    );

    expect(first.samples.first.uri, isNot(second.samples.first.uri));
    expect(
      first.samples
          .map((ProfileLiveNetworkSample sample) => sample.size)
          .toSet(),
      isNot(
        second.samples
            .map((ProfileLiveNetworkSample sample) => sample.size)
            .toSet(),
      ),
    );
  });
}
