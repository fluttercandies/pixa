import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa_gallery/performance/profile_loopback_corpus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'loopback corpus is deterministic, varied, and engine decodable',
    () async {
      final ByteData pngData = await rootBundle.load(
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/'
        'Icon-App-1024x1024@1x.png',
      );
      final Uint8List png = pngData.buffer.asUint8List(
        pngData.offsetInBytes,
        pngData.lengthInBytes,
      );

      final List<ProfileLoopbackImage> first = buildProfileLoopbackCorpus(png);
      final List<ProfileLoopbackImage> second = buildProfileLoopbackCorpus(png);

      expect(first, hasLength(5));
      expect(
        first.map((ProfileLoopbackImage image) => image.mimeType).toSet(),
        <String>{'image/png', 'image/bmp'},
      );
      expect(
        first.map((ProfileLoopbackImage image) => image.encodedBytes).toSet(),
        hasLength(greaterThanOrEqualTo(4)),
      );
      for (var index = 0; index < first.length; index += 1) {
        final ProfileLoopbackImage image = first[index];
        expect(listEquals(image.bytes, second[index].bytes), isTrue);
        expect(image.sha256, hasLength(64));
        expect(image.sha256, second[index].sha256);
        final ui.Codec codec = await ui.instantiateImageCodec(image.bytes);
        addTearDown(codec.dispose);
        final ui.FrameInfo frame = await codec.getNextFrame();
        addTearDown(frame.image.dispose);
        expect(frame.image.width, image.width);
        expect(frame.image.height, image.height);
      }
    },
  );
}
