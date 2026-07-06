import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/src/runtime/capabilities.dart';

void main() {
  test('platform probe rejects Web explicitly', () {
    final PixaRuntimePlatformStatus status = pixaPlatformStatusForProbe(
      isWeb: true,
      targetPlatform: TargetPlatform.macOS,
      runtimeAvailable: true,
    );

    expect(status.platform, 'web');
    expect(status.isWeb, isTrue);
    expect(status.isSupportedPlatform, isFalse);
    expect(status.runtimeAvailable, isFalse);
    expect(status.message, contains('does not support Web'));
  });

  test('platform probe rejects unsupported Flutter platforms', () {
    final PixaRuntimePlatformStatus status = pixaPlatformStatusForProbe(
      isWeb: false,
      targetPlatform: TargetPlatform.fuchsia,
      runtimeAvailable: true,
    );

    expect(status.platform, 'fuchsia');
    expect(status.isSupportedPlatform, isFalse);
    expect(status.runtimeAvailable, isFalse);
    expect(status.message, contains('not supported on fuchsia'));
  });

  test(
    'runtime capabilities fail closed when required runtime core is missing',
    () {
      const PixaRuntimeCapabilities capabilities = PixaRuntimeCapabilities(
        diskCache: false,
        httpTransport: false,
        exifParser: false,
        pixelProcessors: false,
        platformStatus: PixaRuntimePlatformStatus(
          platform: 'linux',
          isWeb: false,
          isSupportedPlatform: true,
          runtimeAvailable: false,
          message: 'Pixa runtime symbols are unavailable on linux.',
        ),
      );

      expect(capabilities.hasRequiredCore, isFalse);
      expect(capabilities.runtimePluginAbiVersion, isNull);
    },
  );

  test('supported platforms expose validation contracts', () {
    final PixaRuntimePlatformStatus status = pixaPlatformStatusForProbe(
      isWeb: false,
      targetPlatform: TargetPlatform.macOS,
      runtimeAvailable: true,
    );

    expect(status.isSupportedPlatform, isTrue);
    expect(status.contract, isNotNull);
    expect(status.contract!.platform, 'macOS');
    expect(status.contract!.targetAbis, <String>['macos-arm64', 'macos-x64']);
    expect(status.contract!.runtimeLibraryLoad, isTrue);
    expect(status.contract!.symbolResolution, isTrue);
    expect(status.contract!.threadedRuntime, isTrue);
    expect(status.contract!.cacheDirectory, isTrue);
    expect(status.contract!.networkPolicy, isTrue);
  });

  test('platform contract matrix covers exactly the supported targets', () {
    expect(
      PixaRuntimePlatformContract.supported.map(
        (PixaRuntimePlatformContract contract) => contract.platform,
      ),
      <String>['android', 'iOS', 'macOS', 'windows', 'linux'],
    );

    expect(
      () => PixaRuntimePlatformContract.forPlatform(TargetPlatform.fuchsia),
      throwsUnsupportedError,
    );
  });

  test(
    'platform self-check passes only when all required runtime contracts pass',
    () {
      final PixaRuntimePlatformSelfCheck check =
          PixaRuntimePlatformSelfCheck.evaluate(
            capabilities: PixaRuntimeCapabilities(
              diskCache: true,
              httpTransport: true,
              exifParser: true,
              pixelProcessors: true,
              runtimePluginAbiVersion: 1,
              platformStatus: pixaPlatformStatusForProbe(
                isWeb: false,
                targetPlatform: TargetPlatform.macOS,
                runtimeAvailable: true,
              ),
            ),
            cacheRootPath: '/tmp/pixa-cache',
          );

      expect(check.platform, 'macOS');
      expect(check.passed, isTrue);
      expect(check.failedChecks, isEmpty);
      expect(
        check.toJson()['checks'],
        isA<List<Object?>>().having(
          (List<Object?> checks) => checks.length,
          'length',
          5,
        ),
      );
    },
  );

  test('platform self-check reports missing runtime and cache directory', () {
    final PixaRuntimePlatformSelfCheck check =
        PixaRuntimePlatformSelfCheck.evaluate(
          capabilities: PixaRuntimeCapabilities(
            diskCache: false,
            httpTransport: false,
            exifParser: false,
            pixelProcessors: false,
            platformStatus: pixaPlatformStatusForProbe(
              isWeb: false,
              targetPlatform: TargetPlatform.linux,
              runtimeAvailable: false,
            ),
          ),
          cacheRootPath: null,
        );

    expect(check.passed, isFalse);
    expect(
      check.failedChecks.map((PixaRuntimePlatformCheck check) => check.name),
      containsAll(<String>[
        'runtimeLibraryLoad',
        'symbolResolution',
        'cacheDirectory',
      ]),
    );
    expect(check.toJson()['passed'], isFalse);
  });
}
