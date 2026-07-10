import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'runtime/runtime_bridge.dart';

/// Stable, redacted key used by Pixa caches and Flutter ImageCache.
@immutable
final class PixaCacheKey {
  /// Creates a cache key from normalized key material.
  factory PixaCacheKey.fromParts(
    Iterable<Object?> parts, {
    String? debugLabel,
  }) {
    if (parts is! List) {
      throw ArgumentError(
        'Cache-key parts must be a List so their order is deterministic.',
      );
    }
    final Uint8List material = _CanonicalCacheKeyEncoder.encode(parts);
    final PixaRuntimeHashPair hashes = PixaRuntimeBridge.cacheKeyHashPair(
      material,
    );
    final String primaryHex = PixaRuntimeBridge.uint64Hex(hashes.primary);
    final String secondaryHex = PixaRuntimeBridge.uint64Hex(hashes.secondary);
    return PixaCacheKey._(
      value: '$primaryHex$secondaryHex',
      materialHash: hashes.secondary,
      debugLabel: debugLabel ?? 'pixa:$primaryHex$secondaryHex',
    );
  }

  const PixaCacheKey._({
    required this.value,
    required this.materialHash,
    required this.debugLabel,
  });

  /// Hex-encoded stable key safe for filenames and logs.
  final String value;

  /// Secondary hash used to reduce accidental collisions in memory structures.
  final int materialHash;

  /// Redacted human-readable label.
  final String debugLabel;

  @override
  bool operator ==(Object other) {
    return other is PixaCacheKey &&
        other.value == value &&
        other.materialHash == materialHash;
  }

  @override
  int get hashCode => Object.hash(value, materialHash);

  @override
  String toString() => debugLabel;
}

final class _CanonicalCacheKeyEncoder {
  _CanonicalCacheKeyEncoder._();

  static Uint8List encode(List<dynamic> parts) {
    return _encodeValue(parts, 'parts');
  }

  static Uint8List _encodeValue(Object? value, String path) {
    if (value == null) {
      return _frame(0x00, Uint8List(0));
    }
    if (value is bool) {
      return _frame(0x01, Uint8List.fromList(<int>[value ? 1 : 0]));
    }
    if (value is int) {
      return _frame(0x02, Uint8List.fromList(utf8.encode(value.toString())));
    }
    if (value is double) {
      if (!value.isFinite) {
        throw ArgumentError('Non-finite double at $path is not deterministic.');
      }
      final ByteData data = ByteData(8)..setFloat64(0, value, Endian.big);
      return _frame(0x03, data.buffer.asUint8List());
    }
    if (value is String) {
      return _frame(0x04, Uint8List.fromList(utf8.encode(value)));
    }
    if (value is Uint8List) {
      return _frame(0x05, value);
    }
    if (value is List) {
      final BytesBuilder payload = BytesBuilder(copy: false);
      for (int index = 0; index < value.length; index++) {
        payload.add(_encodeValue(value[index], '$path[$index]'));
      }
      return _frame(0x06, payload.takeBytes());
    }
    if (value is Map) {
      final List<_CanonicalMapEntry> entries = <_CanonicalMapEntry>[];
      int index = 0;
      for (final MapEntry<dynamic, dynamic> entry in value.entries) {
        entries.add(
          _CanonicalMapEntry(
            _encodeValue(entry.key, '$path.key[$index]'),
            _encodeValue(entry.value, '$path.value[$index]'),
          ),
        );
        index += 1;
      }
      entries.sort(_compareEntries);
      final BytesBuilder payload = BytesBuilder(copy: false);
      for (final _CanonicalMapEntry entry in entries) {
        payload
          ..add(entry.key)
          ..add(entry.value);
      }
      return _frame(0x07, payload.takeBytes());
    }
    throw ArgumentError(
      'Unsupported cache-key value type ${value.runtimeType} at $path; '
      'use null, bool, int, finite double, String, Uint8List, List, or Map.',
    );
  }

  static Uint8List _frame(int tag, Uint8List payload) {
    final ByteData length = ByteData(8)
      ..setUint64(0, payload.length, Endian.big);
    return (BytesBuilder(copy: false)
          ..addByte(tag)
          ..add(length.buffer.asUint8List())
          ..add(payload))
        .takeBytes();
  }

  static int _compareEntries(
    _CanonicalMapEntry first,
    _CanonicalMapEntry second,
  ) {
    final int keyOrder = _compareBytes(first.key, second.key);
    return keyOrder != 0 ? keyOrder : _compareBytes(first.value, second.value);
  }

  static int _compareBytes(Uint8List first, Uint8List second) {
    final int commonLength = first.length < second.length
        ? first.length
        : second.length;
    for (int index = 0; index < commonLength; index++) {
      final int order = first[index].compareTo(second[index]);
      if (order != 0) {
        return order;
      }
    }
    return first.length.compareTo(second.length);
  }
}

final class _CanonicalMapEntry {
  const _CanonicalMapEntry(this.key, this.value);

  final Uint8List key;
  final Uint8List value;
}
