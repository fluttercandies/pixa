import 'dart:collection';

/// Internal registry of Flutter ImageCache keys created by Pixa providers.
final PixaDecodedCacheRegistry pixaDecodedCacheRegistry =
    PixaDecodedCacheRegistry._();

/// Tracks decoded cache keys without owning decoded image data.
final class PixaDecodedCacheRegistry {
  PixaDecodedCacheRegistry._();

  final Map<String, LinkedHashSet<Object>> _keysByNamespace =
      <String, LinkedHashSet<Object>>{};
  final Map<String, LinkedHashSet<Object>> _keysByCacheKey =
      <String, LinkedHashSet<Object>>{};

  /// Records one decoded cache key.
  void track({
    required String namespace,
    required String cacheKey,
    required Object key,
  }) {
    _keysByNamespace.putIfAbsent(namespace, LinkedHashSet<Object>.new).add(key);
    _keysByCacheKey.putIfAbsent(cacheKey, LinkedHashSet<Object>.new).add(key);
  }

  /// Removes and returns all keys associated with one encoded cache key.
  List<Object> takeCacheKey(String cacheKey) {
    final Set<Object> keys =
        _keysByCacheKey.remove(cacheKey) ?? const <Object>{};
    for (final Object key in keys) {
      for (final Set<Object> namespaceKeys in _keysByNamespace.values) {
        namespaceKeys.remove(key);
      }
    }
    _keysByNamespace
        .removeWhere((String namespace, Set<Object> keys) => keys.isEmpty);
    return List<Object>.of(keys);
  }

  /// Removes and returns all keys in one namespace.
  List<Object> takeNamespace(String namespace) {
    final Set<Object> keys =
        _keysByNamespace.remove(namespace) ?? const <Object>{};
    for (final Object key in keys) {
      for (final Set<Object> cacheKeys in _keysByCacheKey.values) {
        cacheKeys.remove(key);
      }
    }
    _keysByCacheKey
        .removeWhere((String cacheKey, Set<Object> keys) => keys.isEmpty);
    return List<Object>.of(keys);
  }

  /// Removes all tracked keys.
  void clear() {
    _keysByNamespace.clear();
    _keysByCacheKey.clear();
  }
}
