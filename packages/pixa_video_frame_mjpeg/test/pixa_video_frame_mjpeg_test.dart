import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa_plugins.dart';
import 'package:pixa_video_frame_mjpeg/pixa_video_frame_mjpeg.dart';

void main() {
  test('MJPEG plugin registers a runtime video-frame backend', () {
    final PixaRegistry registry = PixaRegistry();

    const PixaMjpegVideoFramePlugin(
      hostRuntimeAvailable: true,
    ).register(registry);

    expect(registry.videoFrameBackends, hasLength(1));
    final PixaVideoFrameBackendDescriptor descriptor =
        registry.videoFrameBackends.single;
    expect(descriptor.id, pixaMjpegVideoFrameDescriptorId);
    expect(descriptor.backendId, pixaMjpegVideoFrameBackendId);
    expect(descriptor.executionKind, PixaPluginExecutionKind.runtime);
    expect(descriptor.sourceKinds, pixaMjpegVideoFrameSourceKinds);
    expect(descriptor.capabilities.outputMimeTypes, <String>{'image/jpeg'});
    expect(descriptor.capabilities.nearestFrame, isTrue);
    expect(descriptor.capabilities.exactFrame, isFalse);
    expect(descriptor.capabilities.fileLocator, isTrue);
    expect(descriptor.capabilities.networkLocator, isFalse);
    final PixaRuntimeContract runtime =
        (descriptor as PixaRuntimeDescriptor).runtime;
    expect(runtime.deployment, PixaRuntimeDeployment.hostLinkedPluginModule);
    expect(runtime.moduleId, pixaMjpegVideoFrameModuleId);
    expect(runtime.entrypointSymbol, pixaMjpegVideoFrameEntrypointSymbol);

    final PixaCompiledRoutePlan routePlan = registry.compileRoutePlan();
    expect(
      routePlan.fetcherForSourceKind('video-frame:mjpeg')?.id,
      pixaMjpegVideoFrameDescriptorId,
    );
    expect(routePlan.fetcherRoutes, 1);
    expect(routePlan.architecture.videoFrameBackends, 1);
    expect(
      registry.adaptiveIntegrationSelections.single.pluginId,
      pixaMjpegVideoFramePluginId,
    );
    expect(
      registry.adaptiveIntegrationSelections.single.mode,
      PixaPluginIntegrationMode.runtimeHost,
    );
  });

  test('MJPEG plugin fails fast until the host manifest is enabled', () {
    final PixaRegistry registry = PixaRegistry();

    expect(
      () => const PixaMjpegVideoFramePlugin().register(registry),
      throwsA(
        isA<StateError>()
            .having(
              (StateError error) => error.message,
              'message',
              contains('pixa_video_frame_mjpeg'),
            )
            .having(
              (StateError error) => error.message,
              'message',
              contains('plugin_manifest'),
            ),
      ),
    );
  });

  test('MJPEG helper creates a runtime-only video-frame request', () {
    final PixaRequest request = PixaMjpegVideoFrame.request(
      '/media/camera-roll.avi',
      timestamp: const Duration(milliseconds: 2500),
      targetSize: const PixaTargetSize(width: 320, height: 180),
      priority: PixaPriority.high,
    );

    expect(request.source, isA<PixaVideoFrameSource>());
    final PixaVideoFrameSource source = request.source as PixaVideoFrameSource;
    expect(source.locator, '/media/camera-roll.avi');
    expect(source.options.normalizedBackend, pixaMjpegVideoFrameBackendId);
    expect(source.options.frameSelection, PixaVideoFrameSelection.nearest);
    expect(source.options.timestamp, const Duration(milliseconds: 2500));
    expect(request.targetSize, const PixaTargetSize(width: 320, height: 180));
    expect(request.priority, PixaPriority.high);
    expect(
      request.pluginExecutionPolicy,
      const PixaPluginExecutionPolicy.runtimeOnly(),
    );
  });

  test('MJPEG image helper uses the MJPEG backend route', () {
    final PixaImage image = PixaMjpegVideoFrame.image(
      '/media/camera-roll.avi',
      timestamp: const Duration(seconds: 3),
      width: 160,
      height: 90,
    );

    final PixaVideoFrameSource source =
        image.request.source as PixaVideoFrameSource;
    expect(source.options.normalizedBackend, pixaMjpegVideoFrameBackendId);
    expect(
      image.request.targetSize,
      const PixaTargetSize(width: 160, height: 90),
    );
  });

  test('MJPEG runtime manifest is publishable from package root', () {
    final File manifest = File('pixa_plugin.json');
    final String source = manifest.readAsStringSync();

    expect(source, contains('"schema": 1'));
    expect(source, contains('"moduleId": "$pixaMjpegVideoFrameModuleId"'));
    expect(source, contains('"packageName": "pixa_video_frame_mjpeg"'));
    expect(
      source,
      contains('"entrypointSymbol": "$pixaMjpegVideoFrameEntrypointSymbol"'),
    );
    expect(source, contains('"fetcherSourceKinds": ["video-frame:mjpeg"]'));
    expect(source, contains('"videoFrameOutputMimeTypes": ["image/jpeg"]'));
    expect(source, contains('"videoFrameNearest": true'));
    expect(source, contains('"videoFrameExact": false'));
  });
}
