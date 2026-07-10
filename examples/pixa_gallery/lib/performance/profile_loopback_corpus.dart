import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// One deterministic encoded image served by the loopback profile origin.
final class ProfileLoopbackImage {
  ProfileLoopbackImage({
    required this.id,
    required this.mimeType,
    required this.width,
    required this.height,
    required Uint8List bytes,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final String id;
  final String mimeType;
  final int width;
  final int height;
  final Uint8List bytes;

  int get encodedBytes => bytes.length;

  late final String sha256 = crypto.sha256.convert(bytes).toString();

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'mimeType': mimeType,
      'width': width,
      'height': height,
      'encodedBytes': encodedBytes,
      'sha256': sha256,
    };
  }
}

/// SHA-256 identity for the ordered encoded fixture corpus.
String profileLoopbackCorpusSha256(List<ProfileLoopbackImage> corpus) {
  final BytesBuilder encoded = BytesBuilder(copy: false);
  for (final ProfileLoopbackImage image in corpus) {
    encoded.add(image.bytes);
  }
  return crypto.sha256.convert(encoded.takeBytes()).toString();
}

/// Builds a stable mixed-format corpus without relying on an external service.
List<ProfileLoopbackImage> buildProfileLoopbackCorpus(Uint8List pngFixture) {
  return List<ProfileLoopbackImage>.unmodifiable(<ProfileLoopbackImage>[
    ProfileLoopbackImage(
      id: 'app-icon-png',
      mimeType: 'image/png',
      width: 1024,
      height: 1024,
      bytes: pngFixture,
    ),
    _patternBmp('pattern-bmp-64x64', width: 64, height: 64, seed: 1),
    _patternBmp('pattern-bmp-96x144', width: 96, height: 144, seed: 2),
    _patternBmp('pattern-bmp-160x90', width: 160, height: 90, seed: 3),
    _patternBmp('pattern-bmp-192x128', width: 192, height: 128, seed: 4),
  ]);
}

ProfileLoopbackImage _patternBmp(
  String id, {
  required int width,
  required int height,
  required int seed,
}) {
  final int rowStride = ((width * 3 + 3) ~/ 4) * 4;
  final int pixelBytes = rowStride * height;
  final int fileBytes = 54 + pixelBytes;
  final ByteData data = ByteData(fileBytes);
  data
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4d)
    ..setUint32(2, fileBytes, Endian.little)
    ..setUint32(10, 54, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, width, Endian.little)
    ..setInt32(22, height, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 24, Endian.little)
    ..setUint32(34, pixelBytes, Endian.little)
    ..setInt32(38, 2835, Endian.little)
    ..setInt32(42, 2835, Endian.little);
  for (var storedY = 0; storedY < height; storedY += 1) {
    final int y = height - 1 - storedY;
    final int rowOffset = 54 + storedY * rowStride;
    for (var x = 0; x < width; x += 1) {
      final int offset = rowOffset + x * 3;
      data
        ..setUint8(offset, (x * 13 + y * 3 + seed * 17) & 0xff)
        ..setUint8(offset + 1, (x * 5 + y * 11 + seed * 29) & 0xff)
        ..setUint8(offset + 2, (x * 7 + y * 19 + seed * 37) & 0xff);
    }
  }
  return ProfileLoopbackImage(
    id: id,
    mimeType: 'image/bmp',
    width: width,
    height: height,
    bytes: data.buffer.asUint8List(),
  );
}
