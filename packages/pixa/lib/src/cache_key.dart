import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'runtime/runtime_bridge.dart';

/// Stable, redacted key used by Pixa caches and Flutter ImageCache.
@immutable
final class PixaCacheKey {
  /// Creates a cache key from normalized key material.
  factory PixaCacheKey.fromParts(Iterable<Object?> parts,
      {String? debugLabel}) {
    final String material = parts.map(_normalizePart).join('\n');
    final PixaRuntimeHashPair hashes = PixaRuntimeBridge.cacheKeyHashPair(
      Uint8List.fromList(utf8.encode(material)),
    );
    final String primaryHex = PixaRuntimeBridge.uint64Hex(hashes.primary);
    return PixaCacheKey._(
      value: primaryHex,
      materialHash: hashes.secondary,
      debugLabel: debugLabel ?? 'pixa:$primaryHex',
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

String _normalizePart(Object? value) {
  if (value == null) {
    return '<null>';
  }
  if (value is Map) {
    final List<MapEntry<String, String>> entries =
        value.entries.map((MapEntry<Object?, Object?> entry) {
      return MapEntry<String, String>(
        _normalizePart(entry.key),
        _normalizePart(entry.value),
      );
    }).toList()
          ..sort((MapEntry<String, String> a, MapEntry<String, String> b) {
            return a.key.compareTo(b.key);
          });
    return entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join('&');
  }
  if (value is Iterable && value is! String) {
    return value.map(_normalizePart).join(',');
  }
  return value.toString();
}
