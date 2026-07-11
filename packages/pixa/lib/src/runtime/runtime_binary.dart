import 'dart:convert';
import 'dart:typed_data';

/// Bounds-checked reader for Pixa's internal runtime binary ABI.
final class PixaRuntimeBinaryReader {
  /// Creates a reader over [bytes].
  PixaRuntimeBinaryReader(this._bytes);

  final Uint8List _bytes;
  int _offset = 0;

  /// Whether every byte has been consumed.
  bool get isComplete => _offset == _bytes.length;

  /// Reads and validates a four-byte magic value.
  bool readMagic(int a, int b, int c, int d) {
    if (_bytes.length < 4) {
      return false;
    }
    final bool matches =
        _bytes[0] == a && _bytes[1] == b && _bytes[2] == c && _bytes[3] == d;
    if (matches) {
      _offset = 4;
    }
    return matches;
  }

  /// Reads an unsigned byte.
  int readUint8() {
    final Uint8List bytes = _take(1);
    return bytes[0];
  }

  /// Reads a little-endian unsigned 32-bit integer.
  int readUint32() {
    final Uint8List bytes = _take(4);
    return ByteData.sublistView(bytes).getUint32(0, Endian.little);
  }

  /// Reads a little-endian unsigned 64-bit integer.
  int readUint64() {
    final Uint8List bytes = _take(8);
    return ByteData.sublistView(bytes).getUint64(0, Endian.little);
  }

  /// Reads a little-endian signed 64-bit integer.
  int readInt64() {
    final Uint8List bytes = _take(8);
    return ByteData.sublistView(bytes).getInt64(0, Endian.little);
  }

  /// Reads a length-prefixed UTF-8 string with an optional byte bound.
  String readString({int? maxByteLength}) {
    final int length = readUint32();
    if (maxByteLength != null && length > maxByteLength) {
      throw const FormatException('Runtime binary string exceeds byte limit.');
    }
    final Uint8List bytes = _take(length);
    return utf8.decode(bytes);
  }

  Uint8List _take(int length) {
    final int end = _offset + length;
    if (length < 0 || end > _bytes.length) {
      throw const FormatException('Truncated runtime binary payload.');
    }
    final Uint8List slice = Uint8List.sublistView(_bytes, _offset, end);
    _offset = end;
    return slice;
  }
}
