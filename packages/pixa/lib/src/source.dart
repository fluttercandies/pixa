import 'package:flutter/services.dart';

import 'runtime/runtime_bridge.dart';
import 'redaction.dart';

final Expando<String> _bytesSourceFingerprints =
    Expando<String>('PixaBytesSource.fingerprint');

/// Function used by custom sources to provide encoded bytes.
typedef PixaCustomSourceLoader = Future<Uint8List> Function();

/// Image source handled by the Pixa pipeline.
sealed class PixaSource {
  const PixaSource();

  /// Creates a network source.
  factory PixaSource.network(Uri uri) = PixaNetworkSource;

  /// Creates a filesystem source.
  factory PixaSource.file(String path) = PixaFileSource;

  /// Creates a JPEG EXIF thumbnail source for a filesystem image.
  factory PixaSource.exifThumbnail(String path) = PixaExifThumbnailSource;

  /// Creates an asset source.
  factory PixaSource.asset(String name,
      {String? package, AssetBundle? bundle}) = PixaAssetSource;

  /// Creates an immutable memory source.
  factory PixaSource.memory(String id, Uint8List bytes) = PixaMemorySource;

  /// Creates an immutable byte source.
  factory PixaSource.bytes(Uint8List bytes, {String? id}) = PixaBytesSource;

  /// Creates a custom source routed through a registered fetcher.
  factory PixaSource.custom(String id, PixaCustomSourceLoader loader) =
      PixaCustomSource;

  /// Creates a source routed through a runtime fetcher.
  factory PixaSource.runtimePlugin({
    required String sourceKind,
    required String locator,
  }) = PixaRuntimePluginSource;

  /// Stable source material for cache-key generation.
  Object get cacheMaterial;

  /// Redacted source label safe for logs and observer events.
  String get safeLabel;
}

/// HTTP or HTTPS image source.
final class PixaNetworkSource extends PixaSource {
  /// Creates a network image source.
  const PixaNetworkSource(this.uri);

  /// Network URI.
  final Uri uri;

  @override
  Object get cacheMaterial => <String, Object?>{
        'type': 'network',
        'scheme': uri.scheme.toLowerCase(),
        'host': uri.host.toLowerCase(),
        'port': uri.hasPort ? uri.port : null,
        'path': uri.pathSegments,
        'query': PixaRedactor.redactedQueryMaterial(uri),
      };

  @override
  String get safeLabel => PixaRedactor.redactUri(uri).toString();
}

/// Filesystem image source.
final class PixaFileSource extends PixaSource {
  /// Creates a file image source.
  const PixaFileSource(this.path);

  /// Absolute or app-resolved file path.
  final String path;

  @override
  Object get cacheMaterial => <String, Object?>{
        'type': 'file',
        'path': PixaRedactor.filePathKeyMaterial(path),
      };

  @override
  String get safeLabel => 'file:${PixaRedactor.fileBasename(path)}';
}

/// Embedded JPEG EXIF thumbnail source for a local image.
final class PixaExifThumbnailSource extends PixaSource {
  /// Creates an EXIF thumbnail source.
  const PixaExifThumbnailSource(this.path);

  /// Absolute or app-resolved JPEG file path.
  final String path;

  @override
  Object get cacheMaterial => <String, Object?>{
        'type': 'exifThumbnail',
        'path': PixaRedactor.filePathKeyMaterial(path),
      };

  @override
  String get safeLabel => 'exif-thumbnail:${PixaRedactor.fileBasename(path)}';
}

/// Flutter asset image source.
final class PixaAssetSource extends PixaSource {
  /// Creates an asset image source.
  const PixaAssetSource(this.name, {this.package, this.bundle});

  /// Asset name.
  final String name;

  /// Optional package name.
  final String? package;

  /// Optional asset bundle override.
  final AssetBundle? bundle;

  @override
  Object get cacheMaterial =>
      <String, Object?>{'type': 'asset', 'name': name, 'package': package};

  @override
  String get safeLabel =>
      package == null ? 'asset:$name' : 'asset:packages/$package/$name';
}

/// Memory object image source.
final class PixaMemorySource extends PixaSource {
  /// Creates a memory image source.
  const PixaMemorySource(this.id, this.bytes);

  /// Caller-provided stable identity.
  final String id;

  /// Encoded image bytes.
  final Uint8List bytes;

  @override
  Object get cacheMaterial =>
      <String, Object?>{'type': 'memory', 'id': id, 'length': bytes.length};

  @override
  String get safeLabel => 'memory:$id';
}

/// Raw encoded bytes image source.
final class PixaBytesSource extends PixaSource {
  /// Creates a bytes image source.
  const PixaBytesSource(this.bytes, {this.id});

  /// Encoded image bytes.
  final Uint8List bytes;

  /// Optional stable identity.
  final String? id;

  @override
  Object get cacheMaterial => <String, Object?>{
        'type': 'bytes',
        'id': id,
        'length': bytes.length,
        'fingerprint': _bytesSourceFingerprint(bytes),
      };

  @override
  String get safeLabel => id == null ? 'bytes:${bytes.length}' : 'bytes:$id';
}

String _bytesSourceFingerprint(Uint8List bytes) {
  return _bytesSourceFingerprints[bytes] ??= PixaRuntimeBridge.hashHex(bytes);
}

/// Custom image source.
final class PixaCustomSource extends PixaSource {
  /// Creates a custom image source.
  const PixaCustomSource(this.id, this.loader);

  /// Stable custom source identity.
  final String id;

  /// Loader used by the default custom fetcher.
  final PixaCustomSourceLoader loader;

  @override
  Object get cacheMaterial => <String, Object?>{'type': 'custom', 'id': id};

  @override
  String get safeLabel => 'custom:$id';
}

/// Runtime plugin source.
final class PixaRuntimePluginSource extends PixaSource {
  /// Creates a runtime plugin source.
  const PixaRuntimePluginSource({
    required this.sourceKind,
    required this.locator,
  });

  /// Source kind claimed by a runtime fetcher module.
  final String sourceKind;

  /// runtime fetcher locator, such as `s3://bucket/key`.
  final String locator;

  @override
  Object get cacheMaterial => <String, Object?>{
        'type': 'runtimePlugin',
        'sourceKind': sourceKind.trim().toLowerCase(),
        'locator': _runtimeLocatorKeyMaterial(locator),
      };

  @override
  String get safeLabel => 'runtime-plugin:${sourceKind.trim()}';
}

Object _runtimeLocatorKeyMaterial(String locator) {
  final Uri? uri = Uri.tryParse(locator);
  if (uri != null && uri.hasScheme) {
    return <String, Object?>{
      'scheme': uri.scheme.toLowerCase(),
      'host': uri.host.toLowerCase(),
      'path': uri.pathSegments,
      'query': PixaRedactor.redactedQueryMaterial(uri),
      'privateQuery': PixaRedactor.privateUriQueryPartitionMaterial(uri),
    };
  }
  return PixaRedactor.redactText(locator);
}
