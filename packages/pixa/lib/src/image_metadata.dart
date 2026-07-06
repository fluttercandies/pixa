import 'dart:typed_data';

import 'large_image/tile_plan.dart';
import 'runtime/runtime_bridge.dart';

/// Encoded image format identified from runtime metadata probing.
enum PixaImageMetadataFormat {
  /// JPEG image.
  jpeg,

  /// PNG image.
  png,

  /// GIF image.
  gif,

  /// WebP image.
  webp,

  /// BMP image.
  bmp,

  /// WBMP image.
  wbmp,

  /// ICO image.
  ico,

  /// TIFF image.
  tiff,

  /// PNM image.
  pnm,

  /// QOI image.
  qoi,

  /// TGA image.
  tga,

  /// DDS image.
  dds,

  /// Radiance HDR image.
  hdr,

  /// Farbfeld image.
  farbfeld,

  /// PCX image.
  pcx,

  /// SGI RGB image.
  sgi,

  /// XBM image.
  xbm,

  /// XPM image.
  xpm,
}

/// Image metadata parsed from encoded headers without full pixel decode.
final class PixaImageMetadata {
  /// Creates image metadata.
  const PixaImageMetadata({
    required this.width,
    required this.height,
    required this.format,
    required this.isProgressive,
    required this.isAnimated,
  });

  /// Parses metadata from encoded image bytes through the runtime header parser.
  factory PixaImageMetadata.parseEncoded(Uint8List bytes) {
    return decodeRuntimeImageMetadataForTest(
      PixaRuntimeBridge.imageMetadataPayload(bytes),
    );
  }

  /// Width in encoded image pixels.
  final int width;

  /// Height in encoded image pixels.
  final int height;

  /// Encoded image format.
  final PixaImageMetadataFormat format;

  /// Whether the encoded image is a progressive JPEG.
  final bool isProgressive;

  /// Whether the encoded header declares animation.
  final bool isAnimated;

  /// Dimensions usable by [PixaLargeImage].
  PixaLargeImageSize get size =>
      PixaLargeImageSize(width: width, height: height);
}

/// Decodes `PXI1` metadata payloads from the internal binary ABI.
PixaImageMetadata decodeRuntimeImageMetadataForTest(Uint8List bytes) {
  if (bytes.length != 14 ||
      bytes[0] != 0x50 ||
      bytes[1] != 0x58 ||
      bytes[2] != 0x49 ||
      bytes[3] != 0x31) {
    throw const FormatException('Invalid runtime image metadata payload.');
  }
  final ByteData data = ByteData.sublistView(bytes);
  final int width = data.getUint32(4, Endian.little);
  final int height = data.getUint32(8, Endian.little);
  if (width == 0 || height == 0) {
    throw const FormatException('runtime image metadata dimensions are zero.');
  }
  return PixaImageMetadata(
    width: width,
    height: height,
    format: pixaImageMetadataFormatFromRuntimeCode(bytes[12]),
    isProgressive: bytes[13] & 0x01 != 0,
    isAnimated: bytes[13] & 0x02 != 0,
  );
}

/// Converts a stable runtime metadata format code into the Dart enum.
PixaImageMetadataFormat pixaImageMetadataFormatFromRuntimeCode(int code) {
  switch (code) {
    case 1:
      return PixaImageMetadataFormat.jpeg;
    case 2:
      return PixaImageMetadataFormat.png;
    case 3:
      return PixaImageMetadataFormat.gif;
    case 4:
      return PixaImageMetadataFormat.webp;
    case 5:
      return PixaImageMetadataFormat.bmp;
    case 6:
      return PixaImageMetadataFormat.wbmp;
    case 7:
      return PixaImageMetadataFormat.ico;
    case 8:
      return PixaImageMetadataFormat.tiff;
    case 9:
      return PixaImageMetadataFormat.pnm;
    case 10:
      return PixaImageMetadataFormat.qoi;
    case 11:
      return PixaImageMetadataFormat.tga;
    case 12:
      return PixaImageMetadataFormat.dds;
    case 13:
      return PixaImageMetadataFormat.hdr;
    case 14:
      return PixaImageMetadataFormat.farbfeld;
    case 15:
      return PixaImageMetadataFormat.pcx;
    case 16:
      return PixaImageMetadataFormat.sgi;
    case 17:
      return PixaImageMetadataFormat.xbm;
    case 18:
      return PixaImageMetadataFormat.xpm;
  }
  throw FormatException('Unknown runtime image metadata format: $code');
}
