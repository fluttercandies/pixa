import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as allocator;

import '../cache_key.dart';
import 'runtime_abi_validation.dart';
import 'runtime_loader.dart';

/// Thin Dart wrapper around the Rust-backed encoded disk cache.
final class PixaRuntimeDiskCache {
  /// Creates a runtime disk cache rooted under a platform cache directory.
  const PixaRuntimeDiskCache({required this.rootPath});

  /// Platform cache root path.
  final String rootPath;

  /// Reads an encoded cache entry.
  PixaRuntimeOwnedBuffer? read({
    required String namespace,
    required PixaCacheKey key,
  }) {
    return _withUtf8(rootPath, (Pointer<Uint8> rootPtr, int rootLen) {
      return _withUtf8(namespace, (
        Pointer<Uint8> namespacePtr,
        int namespaceLen,
      ) {
        return _withUtf8(key.value, (Pointer<Uint8> keyPtr, int keyLen) {
          final Pointer<UintPtr> outLen = allocator.calloc<UintPtr>();
          try {
            final Pointer<Uint8> ptr = _diskRead(
              rootPtr,
              rootLen,
              namespacePtr,
              namespaceLen,
              keyPtr,
              keyLen,
              outLen,
            );
            final int length = outLen.value;
            if (ptr == nullptr || length == 0) {
              return null;
            }
            return PixaRuntimeOwnedBuffer.takePointer(ptr, length);
          } finally {
            allocator.calloc.free(outLen);
          }
        });
      });
    });
  }

  /// Checks whether an encoded disk entry exists without reading its bytes.
  bool contains({
    required String namespace,
    required PixaCacheKey key,
    bool allowStale = false,
  }) {
    return _withUtf8(rootPath, (Pointer<Uint8> rootPtr, int rootLen) {
      return _withUtf8(namespace, (
        Pointer<Uint8> namespacePtr,
        int namespaceLen,
      ) {
        return _withUtf8(key.value, (Pointer<Uint8> keyPtr, int keyLen) {
          final int result = _diskContains(
            rootPtr,
            rootLen,
            namespacePtr,
            namespaceLen,
            keyPtr,
            keyLen,
            allowStale,
          );
          if (result == 0) {
            return true;
          }
          if (result == 1) {
            return false;
          }
          throw StateError('Failed to probe Pixa encoded disk cache.');
        });
      });
    });
  }

  /// Writes an encoded cache entry.
  bool write({
    required String namespace,
    required PixaCacheKey key,
    required Uint8List bytes,
    Duration? ttl,
  }) {
    validatePixaOptionalTtl(ttl, 'ttl');
    return _withUtf8(rootPath, (Pointer<Uint8> rootPtr, int rootLen) {
      return _withUtf8(namespace, (
        Pointer<Uint8> namespacePtr,
        int namespaceLen,
      ) {
        return _withUtf8(key.value, (Pointer<Uint8> keyPtr, int keyLen) {
          return _withBytes(bytes, (Pointer<Uint8> bytesPtr, int bytesLen) {
            final int result = _diskWrite(
              rootPtr,
              rootLen,
              namespacePtr,
              namespaceLen,
              keyPtr,
              keyLen,
              bytesPtr,
              bytesLen,
              ttl?.inMilliseconds ?? -1,
            );
            return result == 0;
          });
        });
      });
    });
  }

  /// Removes one encoded cache entry.
  bool remove({required String namespace, required PixaCacheKey key}) {
    return _withUtf8(rootPath, (Pointer<Uint8> rootPtr, int rootLen) {
      return _withUtf8(namespace, (
        Pointer<Uint8> namespacePtr,
        int namespaceLen,
      ) {
        return _withUtf8(key.value, (Pointer<Uint8> keyPtr, int keyLen) {
          return _diskRemove(
                rootPtr,
                rootLen,
                namespacePtr,
                namespaceLen,
                keyPtr,
                keyLen,
              ) ==
              0;
        });
      });
    });
  }

  /// Clears all entries in one namespace.
  bool clearNamespace(String namespace) {
    return _withUtf8(rootPath, (Pointer<Uint8> rootPtr, int rootLen) {
      return _withUtf8(namespace, (
        Pointer<Uint8> namespacePtr,
        int namespaceLen,
      ) {
        return _diskClearNamespace(
              rootPtr,
              rootLen,
              namespacePtr,
              namespaceLen,
            ) ==
            0;
      });
    });
  }

  /// Clears the full encoded disk cache.
  bool clearAll() {
    return _withUtf8(rootPath, (Pointer<Uint8> rootPtr, int rootLen) {
      return _diskClearAll(rootPtr, rootLen) == 0;
    });
  }
}

T _withUtf8<T>(String value, T Function(Pointer<Uint8>, int) operation) {
  final Uint8List bytes = Uint8List.fromList(utf8.encode(value));
  return _withBytes(bytes, operation);
}

T _withBytes<T>(Uint8List bytes, T Function(Pointer<Uint8>, int) operation) {
  validatePixaPortableUintPtr(bytes.length, 'bytes.length');
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

@Native<
  Int32 Function(
    Pointer<Uint8>,
    UintPtr,
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
  symbol: 'pixa_disk_write',
  isLeaf: false,
)
external int _diskWrite(
  Pointer<Uint8> rootPtr,
  int rootLen,
  Pointer<Uint8> namespacePtr,
  int namespaceLen,
  Pointer<Uint8> keyPtr,
  int keyLen,
  Pointer<Uint8> bytesPtr,
  int bytesLen,
  int ttlMillis,
);

@Native<
  Pointer<Uint8> Function(
    Pointer<Uint8>,
    UintPtr,
    Pointer<Uint8>,
    UintPtr,
    Pointer<Uint8>,
    UintPtr,
    Pointer<UintPtr>,
  )
>(assetId: 'package:pixa/pixa_runtime', symbol: 'pixa_disk_read', isLeaf: false)
external Pointer<Uint8> _diskRead(
  Pointer<Uint8> rootPtr,
  int rootLen,
  Pointer<Uint8> namespacePtr,
  int namespaceLen,
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
    Bool,
  )
>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_disk_contains',
  isLeaf: false,
)
external int _diskContains(
  Pointer<Uint8> rootPtr,
  int rootLen,
  Pointer<Uint8> namespacePtr,
  int namespaceLen,
  Pointer<Uint8> keyPtr,
  int keyLen,
  bool allowStale,
);

@Native<
  Int32 Function(
    Pointer<Uint8>,
    UintPtr,
    Pointer<Uint8>,
    UintPtr,
    Pointer<Uint8>,
    UintPtr,
  )
>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_disk_remove',
  isLeaf: false,
)
external int _diskRemove(
  Pointer<Uint8> rootPtr,
  int rootLen,
  Pointer<Uint8> namespacePtr,
  int namespaceLen,
  Pointer<Uint8> keyPtr,
  int keyLen,
);

@Native<Int32 Function(Pointer<Uint8>, UintPtr, Pointer<Uint8>, UintPtr)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_disk_clear_namespace',
  isLeaf: false,
)
external int _diskClearNamespace(
  Pointer<Uint8> rootPtr,
  int rootLen,
  Pointer<Uint8> namespacePtr,
  int namespaceLen,
);

@Native<Int32 Function(Pointer<Uint8>, UintPtr)>(
  assetId: 'package:pixa/pixa_runtime',
  symbol: 'pixa_disk_clear_all',
  isLeaf: false,
)
external int _diskClearAll(Pointer<Uint8> rootPtr, int rootLen);
