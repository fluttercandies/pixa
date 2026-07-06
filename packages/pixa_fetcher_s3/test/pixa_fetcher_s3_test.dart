import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa_plugins.dart';
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
}
