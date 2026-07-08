import 'dart:typed_data';

import 'runtime/runtime_bridge.dart';

/// Low-cost color analysis for encoded image bytes.
final class PixaImageAnalysis {
  /// Creates image analysis.
  const PixaImageAnalysis({
    required this.width,
    required this.height,
    required this.averageArgb,
    required this.dominantArgb,
    required this.paletteArgb,
  });

  /// Runs runtime analysis for encoded image bytes.
  factory PixaImageAnalysis.parseEncoded(Uint8List bytes) {
    return decodeRuntimeImageAnalysisForTest(
      PixaRuntimeBridge.imageAnalysisPayload(bytes),
    );
  }

  /// Encoded image width.
  final int width;

  /// Encoded image height.
  final int height;

  /// Average color as `0xAARRGGBB`.
  final int averageArgb;

  /// Dominant sampled color as `0xAARRGGBB`.
  final int dominantArgb;

  /// Small sampled palette as `0xAARRGGBB` values.
  final List<int> paletteArgb;
}

/// Decodes `PXA1` image analysis payloads from the runtime ABI.
PixaImageAnalysis decodeRuntimeImageAnalysisForTest(Uint8List bytes) {
  if (bytes.length < 21 ||
      bytes[0] != 0x50 ||
      bytes[1] != 0x58 ||
      bytes[2] != 0x41 ||
      bytes[3] != 0x31) {
    throw const FormatException('Invalid runtime image analysis payload.');
  }
  final ByteData data = ByteData.sublistView(bytes);
  final int width = data.getUint32(4, Endian.little);
  final int height = data.getUint32(8, Endian.little);
  final int averageArgb = data.getUint32(12, Endian.big);
  final int dominantArgb = data.getUint32(16, Endian.big);
  final int paletteCount = bytes[20];
  final int expectedLength = 21 + paletteCount * 4;
  if (width == 0 || height == 0 || bytes.length != expectedLength) {
    throw const FormatException('Invalid runtime image analysis payload.');
  }
  final List<int> palette = <int>[];
  var offset = 21;
  for (var index = 0; index < paletteCount; index += 1) {
    palette.add(data.getUint32(offset, Endian.big));
    offset += 4;
  }
  return PixaImageAnalysis(
    width: width,
    height: height,
    averageArgb: averageArgb,
    dominantArgb: dominantArgb,
    paletteArgb: List<int>.unmodifiable(palette),
  );
}
