import 'dart:collection';

/// Internal registry of Flutter ImageCache keys created by Pixa providers.
final PixaDecodedCacheRegistry pixaDecodedCacheRegistry =
    PixaDecodedCacheRegistry();

/// Tracks decoded cache keys without owning provider/request data.
final class PixaDecodedCacheRegistry {
  /// Creates a weak decoded-key registry.
  PixaDecodedCacheRegistry() {
    _finalizer = Finalizer<_TrackedDecodedKey>(_removeCollected);
  }

  late final Finalizer<_TrackedDecodedKey> _finalizer;
  final LinkedHashSet<_TrackedDecodedKey> _entries =
      LinkedHashSet<_TrackedDecodedKey>.identity();
  final Map<String, LinkedHashSet<_TrackedDecodedKey>> _keysByNamespace =
      <String, LinkedHashSet<_TrackedDecodedKey>>{};
  final Map<String, LinkedHashSet<_TrackedDecodedKey>> _keysByCacheKey =
      <String, LinkedHashSet<_TrackedDecodedKey>>{};
  final Map<int, LinkedHashSet<_TrackedDecodedKey>> _keysByHash =
      <int, LinkedHashSet<_TrackedDecodedKey>>{};

  /// Number of weak provider-key records currently retained.
  int get entryCount => _entries.length;

  /// Records the latest decoded cache key for an equal provider identity.
  void track({
    required String namespace,
    required String cacheKey,
    required Object key,
  }) {
    final int keyHash = key.hashCode;
    final LinkedHashSet<_TrackedDecodedKey>? existingEntries =
        _keysByHash[keyHash];
    if (existingEntries != null) {
      for (final _TrackedDecodedKey entry in List<_TrackedDecodedKey>.of(
        existingEntries,
      )) {
        final Object? existing = entry.key.target;
        if (existing == null) {
          _remove(entry);
          continue;
        }
        if (existing == key) {
          _remove(entry);
          break;
        }
      }
    }

    final _TrackedDecodedKey entry = _TrackedDecodedKey(
      namespace: namespace,
      cacheKey: cacheKey,
      keyHash: keyHash,
      key: WeakReference<Object>(key),
    );
    _entries.add(entry);
    _keysByHash
        .putIfAbsent(keyHash, LinkedHashSet<_TrackedDecodedKey>.identity)
        .add(entry);
    _keysByNamespace
        .putIfAbsent(namespace, LinkedHashSet<_TrackedDecodedKey>.identity)
        .add(entry);
    _keysByCacheKey
        .putIfAbsent(cacheKey, LinkedHashSet<_TrackedDecodedKey>.identity)
        .add(entry);
    _finalizer.attach(key, entry, detach: entry);
  }

  /// Removes and returns all live keys for one encoded cache key.
  List<Object> takeCacheKey(String cacheKey) {
    return _take(_keysByCacheKey[cacheKey]);
  }

  /// Removes and returns all live keys in one namespace.
  List<Object> takeNamespace(String namespace) {
    return _take(_keysByNamespace[namespace]);
  }

  /// Removes all weak key metadata.
  void clear() {
    for (final _TrackedDecodedKey entry in _entries) {
      _finalizer.detach(entry);
    }
    _entries.clear();
    _keysByNamespace.clear();
    _keysByCacheKey.clear();
    _keysByHash.clear();
  }

  List<Object> _take(LinkedHashSet<_TrackedDecodedKey>? indexedEntries) {
    final List<_TrackedDecodedKey> entries = List<_TrackedDecodedKey>.of(
      indexedEntries ?? const <_TrackedDecodedKey>{},
    );
    final List<Object> keys = <Object>[];
    for (final _TrackedDecodedKey entry in entries) {
      final Object? key = entry.key.target;
      if (key != null) {
        keys.add(key);
      }
      _remove(entry);
    }
    return keys;
  }

  void _removeCollected(_TrackedDecodedKey entry) {
    _remove(entry, detachFinalizer: false);
  }

  void _remove(_TrackedDecodedKey entry, {bool detachFinalizer = true}) {
    if (!_entries.remove(entry)) {
      return;
    }
    if (detachFinalizer) {
      _finalizer.detach(entry);
    }
    _removeIndexed(_keysByNamespace, entry.namespace, entry);
    _removeIndexed(_keysByCacheKey, entry.cacheKey, entry);
    _removeIndexed(_keysByHash, entry.keyHash, entry);
  }

  void _removeIndexed<K>(
    Map<K, LinkedHashSet<_TrackedDecodedKey>> index,
    K key,
    _TrackedDecodedKey entry,
  ) {
    final LinkedHashSet<_TrackedDecodedKey>? entries = index[key];
    if (entries == null) {
      return;
    }
    entries.remove(entry);
    if (entries.isEmpty) {
      index.remove(key);
    }
  }
}

final class _TrackedDecodedKey {
  const _TrackedDecodedKey({
    required this.namespace,
    required this.cacheKey,
    required this.keyHash,
    required this.key,
  });

  final String namespace;
  final String cacheKey;
  final int keyHash;
  final WeakReference<Object> key;
}
