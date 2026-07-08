library;

import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_plugins.dart';

/// Stable plugin id for the official S3 fetcher descriptor.
const String pixaS3FetcherPluginId = 'pixa.fetcher.s3';

/// Fetcher descriptor id registered by [PixaS3FetcherPlugin].
const String pixaS3FetcherDescriptorId = 'pixa.fetcher.s3';

/// Custom source kinds claimed by the S3 descriptor.
const Set<String> pixaS3SourceKinds = <String>{'s3', 's3-object'};

/// Header names consumed by the built-in Rust S3 fetcher.
abstract final class PixaS3Headers {
  /// AWS region used for SigV4 credential scope.
  static const String region = 'x-pixa-s3-region';

  /// AWS access key id.
  static const String accessKeyId = 'x-pixa-s3-access-key-id';

  /// AWS secret access key.
  static const String secretAccessKey = 'x-pixa-s3-secret-access-key';

  /// Optional AWS STS session token.
  static const String sessionToken = 'x-pixa-s3-session-token';

  /// Optional HTTP(S) endpoint for S3-compatible storage.
  static const String endpoint = 'x-pixa-s3-endpoint';

  /// Whether the endpoint should use path-style object URLs.
  static const String forcePathStyle = 'x-pixa-s3-force-path-style';
}

/// AWS credentials used by the built-in S3 fetcher.
final class PixaS3Credentials {
  /// Creates AWS credentials for S3 object requests.
  const PixaS3Credentials({
    required this.accessKeyId,
    required this.secretAccessKey,
    this.sessionToken,
  });

  /// AWS access key id.
  final String accessKeyId;

  /// AWS secret access key.
  final String secretAccessKey;

  /// Optional AWS STS session token.
  final String? sessionToken;

  void _validate() {
    _requireNonEmpty(accessKeyId, 'accessKeyId');
    _requireNonEmpty(secretAccessKey, 'secretAccessKey');
    final String? token = sessionToken;
    if (token != null && token.trim().isEmpty) {
      throw ArgumentError.value(token, 'sessionToken', 'must not be empty');
    }
  }
}

/// Convenience API for S3 object sources and request headers.
abstract final class PixaS3 {
  /// Creates a runtime source for one S3 object.
  static PixaSource source({
    required String bucket,
    required String key,
    String sourceKind = 's3',
  }) {
    final String normalizedBucket = _validatedBucket(bucket);
    final String normalizedKey = _validatedKey(key);
    final String normalizedKind = sourceKind.trim().toLowerCase();
    if (!pixaS3SourceKinds.contains(normalizedKind)) {
      throw ArgumentError.value(
        sourceKind,
        'sourceKind',
        'must be one of ${pixaS3SourceKinds.join(', ')}',
      );
    }
    return PixaSource.runtimePlugin(
      sourceKind: normalizedKind,
      locator: Uri(
        scheme: 's3',
        host: normalizedBucket,
        pathSegments: normalizedKey.split('/'),
      ).toString(),
    );
  }

  /// Creates S3 fetcher headers consumed by the Rust runtime host.
  static Map<String, String> headers({
    required String region,
    required PixaS3Credentials credentials,
    Uri? endpoint,
    bool forcePathStyle = false,
  }) {
    final String normalizedRegion = _requireNonEmpty(region, 'region');
    credentials._validate();
    final Uri? normalizedEndpoint = _validatedEndpoint(endpoint);
    return <String, String>{
      PixaS3Headers.region: normalizedRegion,
      PixaS3Headers.accessKeyId: credentials.accessKeyId.trim(),
      PixaS3Headers.secretAccessKey: credentials.secretAccessKey.trim(),
      if (credentials.sessionToken != null)
        PixaS3Headers.sessionToken: credentials.sessionToken!.trim(),
      if (normalizedEndpoint != null)
        PixaS3Headers.endpoint: normalizedEndpoint.toString(),
      if (forcePathStyle) PixaS3Headers.forcePathStyle: 'true',
    };
  }

  /// Creates a complete Pixa request for one S3 object.
  static PixaRequest request({
    required String bucket,
    required String key,
    required String region,
    required PixaS3Credentials credentials,
    Uri? endpoint,
    bool forcePathStyle = false,
    String sourceKind = 's3',
    Map<String, String> headers = const <String, String>{},
    PixaHeadersPolicy headersPolicy = const PixaHeadersPolicy(),
    String cacheNamespace = 'default',
    PixaTargetSize? targetSize,
    double scale = 1.0,
    List<String> processors = const <String>[],
    Map<String, Object?> decoderOptions = const <String, Object?>{},
    PixaPluginExecutionPolicy pluginExecutionPolicy =
        const PixaPluginExecutionPolicy.runtimeOnly(),
    PixaCachePolicy cachePolicy = const PixaCachePolicy(),
    PixaPriority priority = PixaPriority.normal,
    PixaRetryPolicy retryPolicy = const PixaRetryPolicy.none(),
    PixaRequestLimits limits = const PixaRequestLimits(),
    PixaRedirectPolicy redirectPolicy = const PixaRedirectPolicy(),
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    return PixaRequest(
      source: source(bucket: bucket, key: key, sourceKind: sourceKind),
      headers: <String, String>{
        ...headers,
        ...PixaS3.headers(
          region: region,
          credentials: credentials,
          endpoint: endpoint,
          forcePathStyle: forcePathStyle,
        ),
      },
      headersPolicy: headersPolicy,
      cacheNamespace: cacheNamespace,
      targetSize: targetSize,
      scale: scale,
      processors: processors,
      decoderOptions: decoderOptions,
      pluginExecutionPolicy: pluginExecutionPolicy,
      cachePolicy: cachePolicy,
      priority: priority,
      retryPolicy: retryPolicy,
      limits: limits,
      redirectPolicy: redirectPolicy,
      metadata: metadata,
    );
  }
}

/// Registers the official S3 fetcher descriptor.
///
/// The package reserves the stable plugin and descriptor surface for the
/// runtime transport pipeline. It does not add a Dart HTTP/S3 runtime.
final class PixaS3FetcherPlugin implements PixaPlugin {
  /// Creates the S3 fetcher plugin descriptor.
  const PixaS3FetcherPlugin();

  @override
  String get id => pixaS3FetcherPluginId;

  @override
  PixaVersionConstraint get compatiblePixaVersions =>
      const PixaVersionConstraint(
        minimumInclusive: '1.0.0',
        maximumExclusive: '2.0.0',
      );

  @override
  void register(PixaRegistry registry) {
    registry.registerFetcher(const _PixaS3FetcherDescriptor());
  }
}

final class _PixaS3FetcherDescriptor
    implements PixaFetcherDescriptor, PixaRuntimeDescriptor {
  const _PixaS3FetcherDescriptor();

  @override
  String get id => pixaS3FetcherDescriptorId;

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.runtime;

  @override
  Set<String> get sourceKinds => pixaS3SourceKinds;

  @override
  PixaRuntimeContract get runtime =>
      const PixaRuntimeContract.builtInHostModule(
        moduleId: pixaS3FetcherDescriptorId,
      );
}

String _validatedBucket(String bucket) {
  final String value = _requireNonEmpty(bucket, 'bucket');
  if (value.contains('/') || value.contains('@') || value.contains('\\')) {
    throw ArgumentError.value(bucket, 'bucket', 'is not a valid S3 bucket');
  }
  return value;
}

String _validatedKey(String key) {
  final String value = _requireNonEmpty(key, 'key');
  if (value == '.' || value == '..') {
    throw ArgumentError.value(key, 'key', 'is not a valid S3 object key');
  }
  return value;
}

Uri? _validatedEndpoint(Uri? endpoint) {
  if (endpoint == null) {
    return null;
  }
  if (!endpoint.isAbsolute ||
      (endpoint.scheme != 'http' && endpoint.scheme != 'https') ||
      endpoint.host.isEmpty ||
      endpoint.hasQuery ||
      endpoint.hasFragment) {
    throw ArgumentError.value(
      endpoint,
      'endpoint',
      'must be an absolute HTTP(S) URI without query or fragment',
    );
  }
  return endpoint;
}

String _requireNonEmpty(String value, String name) {
  final String trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return trimmed;
}
