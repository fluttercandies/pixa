import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as allocator;

import '../cache/cache_stats.dart';
import '../cache_key.dart';
import 'runtime_binary.dart';
import 'runtime_loader.dart';

/// Thin Dart wrapper around the Rust encoded memory cache.
final class PixaRuntimeMemoryCache {
  PixaRuntimeMemoryCache._();

  /// Removes one encoded memory entry.
  static bool remove(PixaCacheKey key) {
    return _withUtf8(key.value, (Pointer<Uint8> keyPtr, int keyLen) {
      return _memoryRemove(keyPtr, keyLen) == 0;
    });
  }

  /// Checks whether encoded memory contains a fresh entry.
  static bool contains(PixaCacheKey key) {
    return _withUtf8(key.value, (Pointer<Uint8> keyPtr, int keyLen) {
      final int result = _memoryContains(keyPtr, keyLen);
      if (result == 0) {
        return true;
      }
      if (result == 1) {
        return false;
      }
      throw StateError('Failed to probe Pixa encoded memory cache.');
    });
  }

  /// Reads one processed variant from encoded memory cache.
  static PixaRuntimeOwnedBuffer? readProcessed(PixaCacheKey key) {
    return _withUtf8(key.value, (Pointer<Uint8> keyPtr, int keyLen) {
      final Pointer<UintPtr> outLen = allocator.calloc<UintPtr>();
      try {
        final Pointer<Void> handle = _memoryReadProcessed(
          keyPtr,
          keyLen,
          outLen,
        );
        final int length = outLen.value;
        if (handle == nullptr) {
          return null;
        }
        return PixaRuntimeOwnedBuffer.fromAddress(handle.address, length);
      } finally {
        allocator.calloc.free(outLen);
      }
    });
  }

  /// Writes one processed variant into encoded memory cache.
  static bool writeProcessed({
    required String namespace,
    required PixaCacheKey key,
    required Uint8List bytes,
    Duration? ttl,
  }) {
    return _withUtf8(namespace, (
      Pointer<Uint8> namespacePtr,
      int namespaceLen,
    ) {
      return _withUtf8(key.value, (Pointer<Uint8> keyPtr, int keyLen) {
        return _withBytes(bytes, (Pointer<Uint8> bytesPtr, int bytesLen) {
          return _memoryWriteProcessed(
                namespacePtr,
                namespaceLen,
                keyPtr,
                keyLen,
                bytesPtr,
                bytesLen,
                ttl?.inMilliseconds ?? -1,
              ) ==
              0;
        });
      });
    });
  }

  /// Pins one encoded memory entry against pressure trim while actively used.
  static bool pin(PixaCacheKey key) {
    return _withUtf8(key.value, (Pointer<Uint8> keyPtr, int keyLen) {
      return _memoryPin(keyPtr, keyLen) == 0;
    });
  }

  /// Releases one active encoded memory pin.
  static bool unpin(PixaCacheKey key) {
    return _withUtf8(key.value, (Pointer<Uint8> keyPtr, int keyLen) {
      return _memoryUnpin(keyPtr, keyLen) == 0;
    });
  }

  /// Clears all encoded memory entries.
  static bool clear() => _memoryClear() == 0;

  /// Clears encoded memory entries for one namespace.
  static bool clearNamespace(String namespace) {
    return _withUtf8(namespace, (
      Pointer<Uint8> namespacePtr,
      int namespaceLen,
    ) {
      return _memoryClearNamespace(namespacePtr, namespaceLen) == 0;
    });
  }

  /// Trims encoded memory to the target byte budget.
  static bool trimToBytes(int targetBytes) {
    if (targetBytes < 0) {
      throw ArgumentError.value(
        targetBytes,
        'targetBytes',
        'must not be negative',
      );
    }
    return _memoryTrimToBytes(targetBytes) == 0;
  }

  /// Returns a runtime cache stats snapshot.
  static PixaCacheStats stats() {
    final Pointer<UintPtr> outLen = allocator.calloc<UintPtr>();
    try {
      final Pointer<Uint8> ptr = _cacheStats(outLen);
      final int length = outLen.value;
      if (ptr == nullptr || length == 0) {
        throw StateError('runtime cache stats are unavailable.');
      }
      try {
        return decodeRuntimeCacheStatsForTest(ptr.asTypedList(length));
      } finally {
        _bufferFree(ptr, length);
      }
    } finally {
      allocator.calloc.free(outLen);
    }
  }
}

/// Decodes runtime cache stats payloads from the internal binary ABI.
PixaCacheStats decodeRuntimeCacheStatsForTest(Uint8List bytes) {
  try {
    final PixaRuntimeBinaryReader reader = PixaRuntimeBinaryReader(bytes);
    if (!reader.readMagic(0x50, 0x58, 0x53, 0x31)) {
      throw const FormatException('Invalid runtime cache stats payload.');
    }
    final PixaCacheStats stats = PixaCacheStats(
      memoryEntries: reader.readUint64(),
      memoryBytes: reader.readUint64(),
      memoryHits: reader.readUint64(),
      memoryMisses: reader.readUint64(),
      diskHits: reader.readUint64(),
      diskMisses: reader.readUint64(),
      diskWrites: reader.readUint64(),
      diskCorruptionRecoveries: reader.readUint64(),
      evictions: reader.readUint64(),
      staleRevalidatesStarted: reader.readUint64(),
      staleRevalidatesCompleted: reader.readUint64(),
      staleRevalidatesFailed: reader.readUint64(),
      staleRevalidatesSkipped: reader.readUint64(),
      staleRevalidatesInFlight: reader.readUint64(),
      processedMemoryHits: reader.readUint64(),
      processedMemoryMisses: reader.readUint64(),
      processedMemoryEvictions: reader.readUint64(),
      processedDiskHits: reader.readUint64(),
      processedDiskMisses: reader.readUint64(),
      processedDiskStaleHits: reader.readUint64(),
      processedDiskWrites: reader.readUint64(),
      processedDiskCorruptionRecoveries: reader.readUint64(),
      ownedBufferHandlesCreated: reader.readUint64(),
      ownedBufferHandlesFreed: reader.readUint64(),
      ownedBufferBytesExposed: reader.readUint64(),
      progressSessionsCreated: reader.readUint64(),
      progressSessionsFreed: reader.readUint64(),
      progressEventsEmitted: reader.readUint64(),
      progressEventsDropped: reader.readUint64(),
      progressEventsDrained: reader.readUint64(),
    );
    if (!reader.isComplete) {
      throw const FormatException('Trailing runtime cache stats bytes.');
    }
    return stats;
  } on FormatException catch (error) {
    throw StateError(
      'runtime cache stats payload is invalid: ${error.message}',
    );
  }
}

T _withUtf8<T>(String value, T Function(Pointer<Uint8>, int) operation) {
  final Uint8List bytes = Uint8List.fromList(utf8.encode(value));
  return _withBytes(bytes, operation);
}

T _withBytes<T>(Uint8List bytes, T Function(Pointer<Uint8>, int) operation) {
  if (bytes.isEmpty) {
    return operation(nullptr.cast<Uint8>(), 0);
  }
  final Pointer<Uint8> pointer = allocator.calloc<Uint8>(bytes.length);
  try {
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    return operation(pointer, bytes.length);
  } finally {
    allocator.calloc.free(pointer);
  }
}

@Native<Int32 Function(Pointer<Uint8>, UintPtr)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_memory_remove',
  isLeaf: false,
)
external int _memoryRemove(Pointer<Uint8> keyPtr, int keyLen);

@Native<Int32 Function(Pointer<Uint8>, UintPtr)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_memory_contains',
  isLeaf: false,
)
external int _memoryContains(Pointer<Uint8> keyPtr, int keyLen);

@Native<Pointer<Void> Function(Pointer<Uint8>, UintPtr, Pointer<UintPtr>)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_memory_read_processed',
  isLeaf: false,
)
external Pointer<Void> _memoryReadProcessed(
  Pointer<Uint8> keyPtr,
  int keyLen,
  Pointer<UintPtr> outLen,
);

@Native<
  Int32 Function(
    Pointer<Uint8>,
    UintPtr,
    Pointer<Uint8>,
    UintPtr,
    Pointer<Uint8>,
    UintPtr,
    Int64,
  )
>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_memory_write_processed',
  isLeaf: false,
)
external int _memoryWriteProcessed(
  Pointer<Uint8> namespacePtr,
  int namespaceLen,
  Pointer<Uint8> keyPtr,
  int keyLen,
  Pointer<Uint8> bytesPtr,
  int bytesLen,
  int ttlMillis,
);

@Native<Int32 Function(Pointer<Uint8>, UintPtr)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_memory_pin',
  isLeaf: false,
)
external int _memoryPin(Pointer<Uint8> keyPtr, int keyLen);

@Native<Int32 Function(Pointer<Uint8>, UintPtr)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_memory_unpin',
  isLeaf: false,
)
external int _memoryUnpin(Pointer<Uint8> keyPtr, int keyLen);

@Native<Int32 Function()>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_memory_clear',
  isLeaf: false,
)
external int _memoryClear();

@Native<Int32 Function(Pointer<Uint8>, UintPtr)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_memory_clear_namespace',
  isLeaf: false,
)
external int _memoryClearNamespace(
  Pointer<Uint8> namespacePtr,
  int namespaceLen,
);

@Native<Int32 Function(UintPtr)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_memory_trim_to_bytes',
  isLeaf: false,
)
external int _memoryTrimToBytes(int targetBytes);

@Native<Pointer<Uint8> Function(Pointer<UintPtr>)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_cache_stats',
  isLeaf: false,
)
external Pointer<Uint8> _cacheStats(Pointer<UintPtr> outLen);

@Native<Void Function(Pointer<Uint8>, UintPtr)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_buffer_free',
  isLeaf: false,
)
external void _bufferFree(Pointer<Uint8> ptr, int len);
