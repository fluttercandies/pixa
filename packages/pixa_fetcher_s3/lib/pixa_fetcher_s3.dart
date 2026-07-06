library;

import 'package:pixa/pixa_plugins.dart';

/// Stable plugin id for the official S3 fetcher descriptor.
const String pixaS3FetcherPluginId = 'pixa.fetcher.s3';

/// Fetcher descriptor id registered by [PixaS3FetcherPlugin].
const String pixaS3FetcherDescriptorId = 'pixa.fetcher.s3';

/// Custom source kinds claimed by the S3 descriptor.
const Set<String> pixaS3SourceKinds = <String>{'s3', 's3-object'};

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
        minimumInclusive: '0.1.0',
        maximumExclusive: '1.0.0',
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
