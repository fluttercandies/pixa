import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa_plugins.dart';
import 'package:pixa/src/redaction.dart';
import 'package:pixa_fetcher_s3/pixa_fetcher_s3.dart';

void main() {
  test('S3 plugin registers its fetcher descriptor', () {
    final PixaRegistry registry = PixaRegistry();

    const PixaS3FetcherPlugin().register(registry);

    expect(registry.fetchers, hasLength(1));
    final PixaFetcherDescriptor descriptor = registry.fetchers.single;
    expect(descriptor.id, pixaS3FetcherDescriptorId);
    expect(descriptor.executionKind, PixaPluginExecutionKind.runtime);
    expect(descriptor.sourceKinds, pixaS3SourceKinds);
    final PixaRuntimeContract runtime =
        (descriptor as PixaRuntimeDescriptor).runtime;
    expect(runtime.deployment, PixaRuntimeDeployment.builtInHostModule);
    expect(runtime.canLinkIntoHostBinary, isTrue);
    expect(runtime.hostManagedRuntime, isTrue);
  });

  test('S3 helpers keep credentials out of locators and cache labels', () {
    const PixaS3Credentials alpha = PixaS3Credentials(
      accessKeyId: 'AKIDEXAMPLE',
      secretAccessKey: 'alpha-secret',
      sessionToken: 'alpha-session',
    );
    const PixaS3Credentials bravo = PixaS3Credentials(
      accessKeyId: 'AKIDEXAMPLE',
      secretAccessKey: 'bravo-secret',
      sessionToken: 'bravo-session',
    );

    final PixaSource source = PixaS3.source(
      bucket: 'bucket',
      key: 'photos/private cat.gif',
    );
    final PixaRuntimePluginSource runtimeSource =
        source as PixaRuntimePluginSource;
    expect(runtimeSource.sourceKind, 's3');
    expect(runtimeSource.locator, 's3://bucket/photos/private%20cat.gif');
    expect(runtimeSource.locator, isNot(contains('alpha-secret')));
    expect(runtimeSource.locator, isNot(contains('AKIDEXAMPLE')));

    final Map<String, String> headers = PixaS3.headers(
      region: 'us-east-1',
      credentials: alpha,
      endpoint: Uri.parse('http://127.0.0.1:9000'),
      forcePathStyle: true,
    );
    expect(headers[PixaS3Headers.region], 'us-east-1');
    expect(headers[PixaS3Headers.endpoint], 'http://127.0.0.1:9000');
    expect(headers[PixaS3Headers.forcePathStyle], 'true');
    expect(
      PixaRedactor.redactHeaders(headers)[PixaS3Headers.secretAccessKey],
      '<redacted>',
    );
    expect(
      PixaRedactor.redactHeaders(headers)[PixaS3Headers.sessionToken],
      '<redacted>',
    );

    final PixaRequest first = PixaS3.request(
      bucket: 'bucket',
      key: 'photos/private cat.gif',
      region: 'us-east-1',
      credentials: alpha,
    );
    final PixaRequest second = PixaS3.request(
      bucket: 'bucket',
      key: 'photos/private cat.gif',
      region: 'us-east-1',
      credentials: bravo,
    );
    expect(first.encodedCacheKey, isNot(second.encodedCacheKey));
    expect(first.encodedCacheKey.debugLabel, isNot(contains('alpha-secret')));
    expect(second.encodedCacheKey.debugLabel, isNot(contains('bravo-secret')));
  });

  test('S3 provider and image helpers reuse runtime-only request material', () {
    const PixaS3Credentials credentials = PixaS3Credentials(
      accessKeyId: 'AKIDEXAMPLE',
      secretAccessKey: 'alpha-secret',
      sessionToken: 'alpha-session',
    );

    final PixaProvider provider = PixaS3.provider(
      bucket: 'bucket',
      key: 'photos/cat.gif',
      region: 'us-east-1',
      credentials: credentials,
      targetWidth: 120,
      targetHeight: 80,
      cacheNamespace: 's3-private',
      cachePolicy: const PixaCachePolicy(privateDiskCache: true),
      priority: PixaPriority.high,
    );
    final PixaImage image = PixaS3.image(
      bucket: 'bucket',
      key: 'photos/cat.gif',
      region: 'us-east-1',
      credentials: credentials,
      width: 120,
      height: 80,
      fit: BoxFit.cover,
      cacheNamespace: 's3-private',
      cachePolicy: const PixaCachePolicy(privateDiskCache: true),
      priority: PixaPriority.high,
    );

    expect(provider.request.source, isA<PixaRuntimePluginSource>());
    expect(
      provider.request.targetSize,
      const PixaTargetSize(width: 120, height: 80),
    );
    expect(provider.request.cacheNamespace, 's3-private');
    expect(provider.request.priority, PixaPriority.high);
    expect(provider.request.pluginExecutionPolicy.usesRuntimeOnly, isTrue);
    expect(image.request.source, isA<PixaRuntimePluginSource>());
    expect(
      image.request.targetSize,
      const PixaTargetSize(width: 120, height: 80),
    );
    expect(image.fit, BoxFit.cover);
    expect(image.request.cachePolicy.privateDiskCache, isTrue);
    expect(provider.request.encodedCacheKey, image.request.encodedCacheKey);
    expect(
      provider.request.encodedCacheKey.debugLabel,
      isNot(contains('alpha')),
    );
    expect(image.request.encodedCacheKey.debugLabel, isNot(contains('alpha')));
  });
}
