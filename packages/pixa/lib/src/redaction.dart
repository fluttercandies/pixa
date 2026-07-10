import 'dart:convert';
import 'dart:typed_data';

import 'runtime/runtime_bridge.dart';

/// Utilities for removing secrets from cache labels, observer payloads, and errors.
final class PixaRedactor {
  PixaRedactor._();

  static const Set<String> _sensitiveHeaderNames = <String>{
    'authorization',
    'cookie',
    'set-cookie',
    'proxy-authorization',
    'x-api-key',
    'x-auth-token',
    'x-amz-security-token',
    'x-pixa-s3-access-key-id',
    'x-pixa-s3-secret-access-key',
    'x-pixa-s3-session-token',
  };

  static const Set<String> _sensitiveQueryNames = <String>{
    'access_token',
    'auth',
    'authorization',
    'expires',
    'key',
    'policy',
    'signature',
    'sig',
    'token',
    'x-amz-credential',
    'x-amz-signature',
    'x-amz-security-token',
  };

  /// Returns true when a header name is considered sensitive.
  static bool isSensitiveHeader(String name) {
    return _sensitiveHeaderNames.contains(name.toLowerCase());
  }

  /// Returns true when a query parameter name is considered sensitive.
  static bool isSensitiveQuery(String name) {
    final String lower = name.toLowerCase();
    return _sensitiveQueryNames.contains(lower) ||
        lower.contains('token') ||
        lower.contains('signature');
  }

  /// Returns query material safe to include in raw cache-key input.
  static Map<String, Object?> redactedQueryMaterial(Uri uri) {
    if (!uri.hasQuery) {
      return const <String, Object?>{};
    }
    final Map<String, Object?> material = <String, Object?>{};
    for (final MapEntry<String, List<String>> entry
        in uri.queryParametersAll.entries) {
      material[entry.key] = isSensitiveQuery(entry.key)
          ? '<sensitive>'
          : entry.value;
    }
    return material;
  }

  /// Returns hashed secret material used only to partition private cache keys.
  static Map<String, Object?> privateNetworkPartitionMaterial(
    Uri uri,
    Map<String, String> headers,
  ) {
    final Map<String, Object?> material = <String, Object?>{};
    final Map<String, Object?> headerMaterial = privateHeaderPartitionMaterial(
      headers,
    );
    if (headerMaterial.isNotEmpty) {
      material['headers'] = headerMaterial;
    }
    final Map<String, Object?> queryMaterial = privateUriQueryPartitionMaterial(
      uri,
    );
    if (queryMaterial.isNotEmpty) {
      material['query'] = queryMaterial;
    }
    if (uri.userInfo.isNotEmpty) {
      material['userInfo'] = _secretFingerprint(uri.userInfo);
    }
    return material;
  }

  /// Returns hashed sensitive URI query material without exposing secret text.
  static Map<String, Object?> privateUriQueryPartitionMaterial(Uri uri) {
    if (!uri.hasQuery) {
      return const <String, Object?>{};
    }
    final Map<String, Object?> material = <String, Object?>{};
    for (final MapEntry<String, List<String>> entry
        in uri.queryParametersAll.entries) {
      if (isSensitiveQuery(entry.key)) {
        material[entry.key] = entry.value
            .map(_secretFingerprint)
            .toList(growable: false);
      }
    }
    return material;
  }

  /// Returns hashed sensitive headers used only to partition private cache keys.
  static Map<String, Object?> privateHeaderPartitionMaterial(
    Map<String, String> headers,
  ) {
    final Map<String, Object?> material = <String, Object?>{};
    for (final MapEntry<String, String> entry in headers.entries) {
      if (isSensitiveHeader(entry.key)) {
        material[entry.key.toLowerCase()] = _secretFingerprint(entry.value);
      }
    }
    return material;
  }

  /// Returns file path material safe to include in raw cache-key input.
  static Map<String, Object?> filePathKeyMaterial(String path) {
    final String normalized = path.replaceAll('\\', '/');
    return <String, Object?>{
      'pathHash': PixaRuntimeBridge.hashHex(
        Uint8List.fromList(utf8.encode(normalized)),
      ),
      'basename': fileBasename(path),
    };
  }

  /// Returns a basename without parent directory segments.
  static String fileBasename(String path) {
    final String normalized = path.replaceAll('\\', '/');
    final List<String> segments = normalized
        .split('/')
        .where((String segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty) {
      return '<file>';
    }
    return segments.last;
  }

  /// Redacts sensitive headers while preserving non-sensitive values.
  static Map<String, String> redactHeaders(Map<String, String> headers) {
    final Map<String, String> redacted = <String, String>{};
    for (final MapEntry<String, String> entry in headers.entries) {
      redacted[entry.key] = isSensitiveHeader(entry.key)
          ? '<redacted>'
          : entry.value;
    }
    return redacted;
  }

  /// Redacts sensitive query parameters from a URI.
  static Uri redactUri(Uri uri) {
    final Uri redactedUserInfo = uri.userInfo.isEmpty
        ? uri
        : uri.replace(userInfo: '<redacted>');
    if (!redactedUserInfo.hasQuery) {
      return redactedUserInfo;
    }

    final Map<String, List<String>> query = <String, List<String>>{};
    for (final MapEntry<String, List<String>> entry
        in redactedUserInfo.queryParametersAll.entries) {
      query[entry.key] = isSensitiveQuery(entry.key)
          ? <String>['<redacted>']
          : entry.value;
    }

    return redactedUserInfo.replace(
      queryParameters: query.map((String key, List<String> values) {
        return MapEntry<String, String>(key, values.join(','));
      }),
    );
  }

  /// Removes common secret material from arbitrary text.
  static String redactText(String text) {
    final String keyValueRedacted = text.replaceAllMapped(
      RegExp(
        r'\b(authorization|cookie|secret|token|signature|x-pixa-s3-secret-access-key|x-amz-security-token)=((?:bearer\s+)?[^&\s]+)',
        caseSensitive: false,
      ),
      (Match match) => '${match.group(1)}=<redacted>',
    );
    return keyValueRedacted.replaceAllMapped(
      RegExp(r'\b(bearer)\s+[a-z0-9._~+/=-]+', caseSensitive: false),
      (Match match) => '${match.group(1)} <redacted>',
    );
  }

  static String _secretFingerprint(String value) {
    return PixaRuntimeBridge.hashHex(
      Uint8List.fromList(utf8.encode('pixa-secret:$value')),
    );
  }
}
