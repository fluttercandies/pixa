import 'dart:ffi';

import 'package:ffi/ffi.dart' as allocator;
import 'package:flutter/foundation.dart';

import 'runtime_plugin_stats.dart';

/// Thin runtime bridge for Pixa hot-path primitives.
final class PixaRuntimeBridge {
  PixaRuntimeBridge._();

  /// Returns true when runtime symbols are available for this runtime.
  static bool get isAvailable {
    if (kIsWeb) {
      return false;
    }
    try {
      _capabilityBits();
      return true;
    } on Object {
      return false;
    }
  }

  /// Stable runtime hash used for cache keys and disk index entries.
  static int hashBytes(Uint8List bytes) {
    return _withRuntimeBytes(bytes, _pixaFnv1a64);
  }

  /// Stable unsigned hexadecimal hash text.
  static String hashHex(Uint8List bytes) {
    return uint64Hex(hashBytes(bytes));
  }

  /// Formats a possibly signed runtime uint64 value as unsigned fixed-width hex.
  static String uint64Hex(int value) {
    return BigInt.from(value).toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  /// Stable primary/secondary hashes for normalized cache-key material.
  static PixaRuntimeHashPair cacheKeyHashPair(Uint8List bytes) {
    return _withRuntimeBytesAndHashPair(bytes, (
      Pointer<Uint8> ptr,
      int len,
      Pointer<Uint64> primary,
      Pointer<Uint64> secondary,
    ) {
      final int status = _cacheKeyHashPair(ptr, len, primary, secondary);
      if (status != 0) {
        throw StateError('Failed to hash runtime cache key material.');
      }
      return PixaRuntimeHashPair(primary.value, secondary.value);
    });
  }

  /// runtime capability bitset.
  static int capabilityBits() => _capabilityBits();

  /// runtime plugin host ABI version.
  static int runtimePluginAbiVersion() => _runtimePluginAbiVersion();

  /// runtime plugin registry counters.
  static PixaRuntimePluginRegistryStats runtimePluginRegistryStats() {
    final Pointer<UintPtr> outLen = allocator.calloc<UintPtr>();
    try {
      final Pointer<Uint8> ptr = _runtimePluginRegistryStats(outLen);
      final int length = outLen.value;
      if (ptr == nullptr || length == 0) {
        throw StateError('Failed to read runtime plugin registry stats.');
      }
      try {
        return PixaRuntimePluginRegistryStats.decode(ptr.asTypedList(length));
      } finally {
        _bufferFree(ptr, length);
      }
    } finally {
      allocator.calloc.free(outLen);
    }
  }

  /// runtime image format capability payload.
  static Uint8List imageFormatCapabilitiesPayload() {
    final Pointer<UintPtr> outLen = allocator.calloc<UintPtr>();
    try {
      final Pointer<Uint8> ptr = _imageFormatCapabilities(outLen);
      final int length = outLen.value;
      if (ptr == nullptr || length == 0) {
        throw StateError('Failed to read runtime image format capabilities.');
      }
      try {
        return Uint8List.fromList(ptr.asTypedList(length));
      } finally {
        _bufferFree(ptr, length);
      }
    } finally {
      allocator.calloc.free(outLen);
    }
  }

  /// runtime image metadata payload parsed from encoded headers.
  static Uint8List imageMetadataPayload(Uint8List bytes) {
    return _withRuntimeBytesAndBuffer(bytes, _imageMetadata);
  }

  /// Parses JPEG EXIF orientation, returning null when absent.
  static int? jpegExifOrientation(Uint8List bytes) {
    return _withRuntimeBytesAndOut(bytes, (
      Pointer<Uint8> ptr,
      int len,
      Pointer<Uint16> outOrientation,
    ) {
      final int status = _jpegExifOrientation(ptr, len, outOrientation);
      if (status == 1) {
        return null;
      }
      if (status != 0) {
        throw StateError('Failed to parse JPEG EXIF orientation.');
      }
      return outOrientation.value;
    });
  }

  /// Applies runtime configuration.
  static bool configure({
    required int memoryCacheBytes,
    required int diskCacheBytes,
    required int networkConcurrency,
  }) {
    return _configure(memoryCacheBytes, diskCacheBytes, networkConcurrency) ==
        0;
  }
}

/// Primary and secondary cache-key hashes computed by one runtime call.
final class PixaRuntimeHashPair {
  /// Creates a runtime hash pair.
  const PixaRuntimeHashPair(this.primary, this.secondary);

  /// Primary hash used for stable file-safe key text.
  final int primary;

  /// Secondary hash used to reduce accidental in-memory collisions.
  final int secondary;
}

int _withRuntimeBytes(
  Uint8List bytes,
  int Function(Pointer<Uint8>, int) operation,
) {
  if (bytes.isEmpty) {
    return operation(nullptr.cast<Uint8>(), 0);
  }

  final Pointer<Uint8> allocated = allocator.calloc<Uint8>(bytes.length);
  try {
    allocated.asTypedList(bytes.length).setAll(0, bytes);
    return operation(allocated, bytes.length);
  } finally {
    allocator.calloc.free(allocated);
  }
}

T _withRuntimeBytesAndHashPair<T>(
  Uint8List bytes,
  T Function(Pointer<Uint8>, int, Pointer<Uint64>, Pointer<Uint64>) operation,
) {
  final Pointer<Uint64> primary = allocator.calloc<Uint64>();
  final Pointer<Uint64> secondary = allocator.calloc<Uint64>();
  try {
    if (bytes.isEmpty) {
      return operation(nullptr.cast<Uint8>(), 0, primary, secondary);
    }
    final Pointer<Uint8> allocated = allocator.calloc<Uint8>(bytes.length);
    try {
      allocated.asTypedList(bytes.length).setAll(0, bytes);
      return operation(allocated, bytes.length, primary, secondary);
    } finally {
      allocator.calloc.free(allocated);
    }
  } finally {
    allocator.calloc.free(primary);
    allocator.calloc.free(secondary);
  }
}

T _withRuntimeBytesAndOut<T>(
  Uint8List bytes,
  T Function(Pointer<Uint8>, int, Pointer<Uint16>) operation,
) {
  final Pointer<Uint16> out = allocator.calloc<Uint16>();
  try {
    if (bytes.isEmpty) {
      return operation(nullptr.cast<Uint8>(), 0, out);
    }
    final Pointer<Uint8> allocated = allocator.calloc<Uint8>(bytes.length);
    try {
      allocated.asTypedList(bytes.length).setAll(0, bytes);
      return operation(allocated, bytes.length, out);
    } finally {
      allocator.calloc.free(allocated);
    }
  } finally {
    allocator.calloc.free(out);
  }
}

Uint8List _withRuntimeBytesAndBuffer(
  Uint8List bytes,
  Pointer<Uint8> Function(Pointer<Uint8>, int, Pointer<UintPtr>) operation,
) {
  final Pointer<UintPtr> outLen = allocator.calloc<UintPtr>();
  try {
    if (bytes.isEmpty) {
      return _takeRuntimeBuffer(
        operation(nullptr.cast<Uint8>(), 0, outLen),
        outLen.value,
      );
    }
    final Pointer<Uint8> allocated = allocator.calloc<Uint8>(bytes.length);
    try {
      allocated.asTypedList(bytes.length).setAll(0, bytes);
      return _takeRuntimeBuffer(
        operation(allocated, bytes.length, outLen),
        outLen.value,
      );
    } finally {
      allocator.calloc.free(allocated);
    }
  } finally {
    allocator.calloc.free(outLen);
  }
}

Uint8List _takeRuntimeBuffer(Pointer<Uint8> ptr, int length) {
  if (ptr == nullptr || length == 0) {
    throw StateError('Failed to read runtime image metadata.');
  }
  try {
    return Uint8List.fromList(ptr.asTypedList(length));
  } finally {
    _bufferFree(ptr, length);
  }
}

@Native<Uint8 Function()>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_capability_bits',
  isLeaf: true,
)
external int _capabilityBits();

@Native<Uint32 Function()>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_plugin_abi_version',
  isLeaf: true,
)
external int _runtimePluginAbiVersion();

@Native<Pointer<Uint8> Function(Pointer<UintPtr>)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_plugin_registry_stats',
  isLeaf: false,
)
external Pointer<Uint8> _runtimePluginRegistryStats(Pointer<UintPtr> outLen);

@Native<Pointer<Uint8> Function(Pointer<UintPtr>)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_image_format_capabilities',
  isLeaf: false,
)
external Pointer<Uint8> _imageFormatCapabilities(Pointer<UintPtr> outLen);

@Native<Pointer<Uint8> Function(Pointer<Uint8>, UintPtr, Pointer<UintPtr>)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_image_metadata',
  isLeaf: false,
)
external Pointer<Uint8> _imageMetadata(
  Pointer<Uint8> ptr,
  int len,
  Pointer<UintPtr> outLen,
);

@Native<Void Function(Pointer<Uint8>, UintPtr)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_buffer_free',
  isLeaf: false,
)
external void _bufferFree(Pointer<Uint8> ptr, int len);

@Native<Uint64 Function(Pointer<Uint8>, UintPtr)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_fnv1a64',
  isLeaf: true,
)
external int _pixaFnv1a64(Pointer<Uint8> ptr, int len);

@Native<
  Int32 Function(Pointer<Uint8>, UintPtr, Pointer<Uint64>, Pointer<Uint64>)
>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_cache_key_hash_pair',
  isLeaf: true,
)
external int _cacheKeyHashPair(
  Pointer<Uint8> ptr,
  int len,
  Pointer<Uint64> outPrimary,
  Pointer<Uint64> outSecondary,
);

@Native<Int32 Function(Pointer<Uint8>, UintPtr, Pointer<Uint16>)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_jpeg_exif_orientation',
  isLeaf: false,
)
external int _jpegExifOrientation(
  Pointer<Uint8> ptr,
  int len,
  Pointer<Uint16> outOrientation,
);

@Native<Int32 Function(UintPtr, UintPtr, UintPtr)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_configure',
  isLeaf: false,
)
external int _configure(
  int memoryCacheBytes,
  int diskCacheBytes,
  int networkConcurrency,
);
