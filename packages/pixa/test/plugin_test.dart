import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_plugins.dart';
import 'package:pixa/src/image_format_catalog.dart';

const PixaVersionConstraint _compatiblePixa1 = PixaVersionConstraint(
  minimumInclusive: '1.0.0',
  maximumExclusive: '2.0.0',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Pixa exposes the package version used for plugin compatibility', () {
    expect(Pixa.version, '1.0.0');
  });

  test(
    'Pixa.configure rejects incompatible plugins before runtime probing',
    () async {
      final _TestPlugin plugin = _TestPlugin(
        id: 'future-plugin',
        compatiblePixaVersions: const PixaVersionConstraint(
          minimumInclusive: '99.0.0',
          maximumExclusive: '100.0.0',
        ),
      );

      await expectLater(
        Pixa.configure(
          PixaConfig(cacheRootPath: 'unused', plugins: <PixaPlugin>[plugin]),
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('1.0.0'),
          ),
        ),
      );
    },
  );

  test(
    'Pixa.configure rejects duplicate plugin ids before runtime probing',
    () async {
      const _TestPlugin first = _TestPlugin(id: 'duplicate');
      const _TestPlugin second = _TestPlugin(id: 'duplicate');

      await expectLater(
        Pixa.configure(
          const PixaConfig(
            cacheRootPath: 'unused',
            plugins: <PixaPlugin>[first, second],
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('Duplicate Pixa plugin id "duplicate"'),
          ),
        ),
      );
    },
  );

  test('PixaRegistry rejects conflicting fetcher source kinds', () {
    final PixaRegistry registry = PixaRegistry();
    registry.registerFetcher(
      const _FetcherDescriptor(id: 'first', sourceKinds: <String>{'s3'}),
    );

    expect(
      () => registry.registerFetcher(
        const _FetcherDescriptor(id: 'second', sourceKinds: <String>{'s3'}),
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('already registered'),
        ),
      ),
    );
  });

  test('PixaRegistry exposes custom fetcher and decoder descriptors', () {
    final PixaRegistry registry = PixaRegistry();
    const _FetcherDescriptor fetcher = _FetcherDescriptor(
      id: 's3-fetcher',
      sourceKinds: <String>{'s3'},
    );
    const _DecoderDescriptor decoder = _DecoderDescriptor(
      id: 'test-decoder',
      mimeTypes: <String>{'image/x-pixa-test'},
      priority: 100,
    );

    registry
      ..registerFetcher(fetcher)
      ..registerDecoder(decoder);

    expect(registry.fetchers, <PixaFetcherDescriptor>[fetcher]);
    expect(registry.decoders, <PixaDecoderDescriptor>[decoder]);
  });

  test('PixaRuntimeContract supports single-binary host linked modules', () {
    const PixaRuntimeContract contract =
        PixaRuntimeContract.hostLinkedPluginModule(
          moduleId: 'third.party.decoder',
          packageName: 'pixa_decoder_third_party',
          implementationLanguage: 'zig',
          entrypointSymbol: 'pixa_plugin_init',
        );

    expect(contract.deployment, PixaRuntimeDeployment.hostLinkedPluginModule);
    expect(contract.canLinkIntoHostBinary, isTrue);
    expect(contract.hostManagedRuntime, isTrue);
    expect(contract.binaryMessages, isTrue);
    expect(contract.ownedBuffers, isTrue);
    expect(contract.streamHandles, isTrue);
    expect(contract.implementationLanguage, 'zig');
  });

  test(
    'PixaRegistry requires explicit runtime video-frame backend contract',
    () {
      final PixaRegistry registry = PixaRegistry();

      expect(
        () => registry.registerFetcher(
          const _FetcherDescriptor(
            id: 'generic-video-frame',
            sourceKinds: <String>{'video-frame:platform'},
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('video-frame backend'),
          ),
        ),
      );

      const PixaRuntimeVideoFrameBackendDescriptor descriptor =
          PixaRuntimeVideoFrameBackendDescriptor(
            id: 'platform-video-frame',
            backendId: 'platform',
            runtime: PixaRuntimeContract.hostLinkedPluginModule(
              moduleId: 'pixa.video_frame.platform',
              entrypointSymbol: 'pixa_platform_video_frame_plugin_init',
              implementationLanguage: 'swift/kotlin/c++',
            ),
            capabilities: PixaVideoFrameBackendCapabilities.encodedImage(
              outputMimeTypes: <String>{'image/png'},
              exactFrame: true,
              fileLocator: true,
              networkLocator: true,
            ),
          );

      registry.registerFetcher(descriptor);

      expect(registry.videoFrameBackends, <PixaVideoFrameBackendDescriptor>[
        descriptor,
      ]);
      expect(registry.fetcherForSourceKind('video-frame:PLATFORM'), descriptor);
      expect(descriptor.sourceKinds, <String>{'video-frame:platform'});
      expect(descriptor.capabilities.outputMimeTypes, <String>{'image/png'});
      expect(descriptor.capabilities.encodedImageOutput, isTrue);

      final PixaRegistryArchitectureSnapshot snapshot = registry
          .architectureSnapshot();
      expect(snapshot.videoFrameBackends, 1);
      expect(snapshot.videoFrameBackendsUseRuntimeOnly, isTrue);
      expect(snapshot.videoFrameEncodedOutputBackends, 1);
      expect(snapshot.toJson()['videoFrameBackends'], 1);
    },
  );

  test('PixaRequest plugin execution policy is explicit variant material', () {
    final PixaRequest runtimeOnly = PixaRequest.network(
      'https://images.example.test/a.gif',
    );
    final PixaRequest dartAllowed = runtimeOnly.copyWith(
      pluginExecutionPolicy:
          const PixaPluginExecutionPolicy.runtimeFirstWithDart(),
    );
    final PixaRequest platformAllowed = runtimeOnly.copyWith(
      pluginExecutionPolicy:
          const PixaPluginExecutionPolicy.runtimeFirstWithPlatform(),
    );

    expect(runtimeOnly.pluginExecutionPolicy.usesRuntimeOnly, isTrue);
    expect(dartAllowed.pluginExecutionPolicy.dart, isTrue);
    expect(platformAllowed.pluginExecutionPolicy.platform, isTrue);
    expect(dartAllowed.cacheKey, isNot(runtimeOnly.cacheKey));
    expect(platformAllowed.cacheKey, isNot(runtimeOnly.cacheKey));
    expect(dartAllowed.encodedCacheKey, runtimeOnly.encodedCacheKey);
    expect(platformAllowed.encodedCacheKey, runtimeOnly.encodedCacheKey);
  });

  test(
    'PixaRegistry supports platform descriptors and compiled route plan',
    () {
      final PixaRegistry registry = PixaRegistry()
        ..registerFetcher(const _PlatformFetcherDescriptor());

      final PixaRegistryArchitectureSnapshot snapshot = registry
          .architectureSnapshot();
      expect(snapshot.platformHandlers, 1);
      expect(snapshot.defaultHotPathUsesRuntimeOnly, isFalse);
      expect(snapshot.toJson()['platformHandlers'], 1);

      final PixaCompiledRoutePlan routePlan = registry.compileRoutePlan();
      expect(routePlan.fetcherRoutes, 1);
      expect(routePlan.platformHandlers, 1);
      expect(
        routePlan.fetcherForSourceKind('PLATFORM-SOURCE')?.id,
        'platform-fetcher',
      );
      expect(routePlan.platformSourceKinds, <String>{'platform-source'});
      expect(routePlan.toJson()['platformHandlers'], 1);
    },
  );

  test('PixaRegistry adaptive integration prefers available runtime host', () {
    final PixaRegistry registry = PixaRegistry()
      ..registerAdaptiveIntegration(
        pluginId: 'com.example.pixa.adaptive',
        candidates: <PixaPluginIntegrationCandidate>[
          PixaPluginIntegrationCandidate.pureDart(
            id: 'dart',
            packageName: 'pixa_adaptive_example',
            register: _registerAdaptiveDartFetcher,
          ),
          PixaPluginIntegrationCandidate.platformChannel(
            id: 'platform',
            packageName: 'pixa_adaptive_example',
            platformAvailable: true,
            register: _registerAdaptivePlatformFetcher,
          ),
          PixaPluginIntegrationCandidate.runtimeHost(
            id: 'runtime',
            packageName: 'pixa_adaptive_example',
            hostRuntimeAvailable: true,
            register: _registerAdaptiveRuntimeFetcher,
          ),
        ],
      );

    final PixaPluginIntegrationSelection selection =
        registry.adaptiveIntegrationSelections.single;
    expect(selection.pluginId, 'com.example.pixa.adaptive');
    expect(selection.candidateId, 'runtime');
    expect(selection.mode, PixaPluginIntegrationMode.runtimeHost);
    expect(selection.packageName, 'pixa_adaptive_example');

    final PixaCompiledRoutePlan routePlan = registry.compileRoutePlan();
    expect(
      routePlan.fetcherForSourceKind('adaptive-source')?.executionKind,
      PixaPluginExecutionKind.runtime,
    );
    expect(routePlan.fetcherRoutes, 1);
    expect(
      (routePlan.toJson()['adaptivePluginIntegrations']! as List<Object?>)
          .single,
      containsPair('candidateId', 'runtime'),
    );
  });

  test(
    'PixaRegistry adaptive integration falls back when runtime host is absent',
    () {
      final PixaRegistry registry = PixaRegistry()
        ..registerAdaptiveIntegration(
          pluginId: 'com.example.pixa.adaptive',
          candidates: <PixaPluginIntegrationCandidate>[
            PixaPluginIntegrationCandidate.runtimeHost(
              id: 'runtime',
              packageName: 'pixa_adaptive_example',
              hostRuntimeAvailable: false,
              unavailableMessage:
                  'Root app did not enable plugin_manifest for this module.',
              register: _registerAdaptiveRuntimeFetcher,
            ),
            PixaPluginIntegrationCandidate.platformChannel(
              id: 'platform',
              packageName: 'pixa_adaptive_example',
              platformAvailable: true,
              register: _registerAdaptivePlatformFetcher,
            ),
          ],
        );

      expect(
        registry.adaptiveIntegrationSelections.single.mode,
        PixaPluginIntegrationMode.platformChannel,
      );
      expect(
        registry.fetcherForSourceKind('adaptive-source')?.executionKind,
        PixaPluginExecutionKind.platform,
      );
    },
  );

  test('PixaRegistry adaptive integration can fall back to pure Dart', () {
    final PixaRegistry registry = PixaRegistry()
      ..registerAdaptiveIntegration(
        pluginId: 'com.example.pixa.adaptive',
        candidates: <PixaPluginIntegrationCandidate>[
          PixaPluginIntegrationCandidate.runtimeHost(
            id: 'runtime',
            packageName: 'pixa_adaptive_example',
            hostRuntimeAvailable: false,
            register: _registerAdaptiveRuntimeFetcher,
          ),
          PixaPluginIntegrationCandidate.platformChannel(
            id: 'platform',
            packageName: 'pixa_adaptive_example',
            platformAvailable: false,
            register: _registerAdaptivePlatformFetcher,
          ),
          PixaPluginIntegrationCandidate.pureDart(
            id: 'dart',
            packageName: 'pixa_adaptive_example',
            register: _registerAdaptiveDartFetcher,
          ),
        ],
      );

    expect(
      registry.adaptiveIntegrationSelections.single.mode,
      PixaPluginIntegrationMode.pureDart,
    );
    expect(
      registry.fetcherForSourceKind('adaptive-source')?.executionKind,
      PixaPluginExecutionKind.dart,
    );
  });

  test('PixaRegistry adaptive integration can select external fallback', () {
    final PixaRegistry registry = PixaRegistry()
      ..registerAdaptiveIntegration(
        pluginId: 'com.example.pixa.adaptive',
        candidates: <PixaPluginIntegrationCandidate>[
          PixaPluginIntegrationCandidate.runtimeHost(
            id: 'runtime',
            packageName: 'pixa_adaptive_example',
            hostRuntimeAvailable: false,
            register: _registerAdaptiveRuntimeFetcher,
          ),
          PixaPluginIntegrationCandidate.platformChannel(
            id: 'platform',
            packageName: 'pixa_adaptive_example',
            platformAvailable: false,
            register: _registerAdaptivePlatformFetcher,
          ),
          PixaPluginIntegrationCandidate.pureDart(
            id: 'dart',
            packageName: 'pixa_adaptive_example',
            available: false,
            register: _registerAdaptiveDartFetcher,
          ),
          PixaPluginIntegrationCandidate.external(
            id: 'external',
            packageName: 'pixa_adaptive_example',
            register: _registerAdaptiveExternalFetcher,
          ),
        ],
      );

    final PixaPluginIntegrationSelection selection =
        registry.adaptiveIntegrationSelections.single;
    expect(selection.mode, PixaPluginIntegrationMode.external);
    expect(selection.candidateId, 'external');
    expect(
      registry.fetcherForSourceKind('adaptive-source')?.executionKind,
      PixaPluginExecutionKind.external,
    );
  });

  test(
    'PixaRegistry adaptive integration fails for required missing runtime',
    () {
      final PixaRegistry registry = PixaRegistry();

      expect(
        () => registry.registerAdaptiveIntegration(
          pluginId: 'com.example.pixa.required_runtime',
          candidates: <PixaPluginIntegrationCandidate>[
            PixaPluginIntegrationCandidate.runtimeHost(
              id: 'runtime',
              packageName: 'pixa_required_runtime',
              hostRuntimeAvailable: false,
              requiredIntegration: true,
              unavailableMessage:
                  'Root app must provide plugin_manifest for this pub package.',
              register: _registerAdaptiveRuntimeFetcher,
            ),
            PixaPluginIntegrationCandidate.pureDart(
              id: 'dart',
              packageName: 'pixa_required_runtime',
              register: _registerAdaptiveDartFetcher,
            ),
          ],
        ),
        throwsA(
          isA<StateError>()
              .having(
                (StateError error) => error.message,
                'message',
                contains('pixa_required_runtime'),
              )
              .having(
                (StateError error) => error.message,
                'message',
                contains('plugin_manifest'),
              ),
        ),
      );
    },
  );

  test(
    'PixaRegistry adaptive integration can be optional when unavailable',
    () {
      final PixaRegistry registry = PixaRegistry()
        ..registerAdaptiveIntegration(
          pluginId: 'com.example.pixa.optional',
          requireAvailableCandidate: false,
          candidates: <PixaPluginIntegrationCandidate>[
            PixaPluginIntegrationCandidate.runtimeHost(
              id: 'runtime',
              packageName: 'pixa_optional',
              hostRuntimeAvailable: false,
              register: _registerAdaptiveRuntimeFetcher,
            ),
          ],
        );

      expect(registry.adaptiveIntegrationSelections, isEmpty);
      expect(registry.fetchers, isEmpty);
      expect(registry.compileRoutePlan().adaptiveIntegrations, isEmpty);
    },
  );

  test(
    'PixaRegistry adaptive integration does not register unselected routes',
    () {
      final PixaRegistry registry = PixaRegistry()
        ..registerFetcher(
          const _FetcherDescriptor(
            id: 'existing-runtime-only-route',
            sourceKinds: <String>{'runtime-only-adaptive-source'},
          ),
        )
        ..registerAdaptiveIntegration(
          pluginId: 'com.example.pixa.adaptive',
          candidates: <PixaPluginIntegrationCandidate>[
            PixaPluginIntegrationCandidate.runtimeHost(
              id: 'runtime',
              packageName: 'pixa_adaptive_example',
              hostRuntimeAvailable: false,
              register: _registerAdaptiveRuntimeOnlyConflictFetcher,
            ),
            PixaPluginIntegrationCandidate.pureDart(
              id: 'dart',
              packageName: 'pixa_adaptive_example',
              register: _registerAdaptiveDartFetcher,
            ),
          ],
        );

      final PixaCompiledRoutePlan routePlan = registry.compileRoutePlan();
      expect(routePlan.fetcherForSourceKind('adaptive-source')?.id, 'dart');
      expect(
        routePlan.fetcherForSourceKind('runtime-only-adaptive-source')?.id,
        'existing-runtime-only-route',
      );
      expect(routePlan.fetcherRoutes, 2);
    },
  );

  test(
    'PixaRegistry adaptive integration rejects mismatched candidate handlers',
    () {
      final PixaRegistry registry = PixaRegistry();

      expect(
        () => registry.registerAdaptiveIntegration(
          pluginId: 'com.example.pixa.bad_adaptive',
          candidates: <PixaPluginIntegrationCandidate>[
            PixaPluginIntegrationCandidate.runtimeHost(
              id: 'runtime',
              packageName: 'pixa_bad_adaptive',
              hostRuntimeAvailable: true,
              register: _registerAdaptiveDartFetcher,
            ),
          ],
        ),
        throwsA(
          isA<StateError>()
              .having(
                (StateError error) => error.message,
                'message',
                contains('runtimeHost'),
              )
              .having(
                (StateError error) => error.message,
                'message',
                contains('runtime'),
              ),
        ),
      );
      expect(registry.fetchers, isEmpty);
      expect(registry.adaptiveIntegrationSelections, isEmpty);
    },
  );

  test(
    'PixaRegistry adaptive integration requires selected route descriptors',
    () {
      final PixaRegistry registry = PixaRegistry();

      expect(
        () => registry.registerAdaptiveIntegration(
          pluginId: 'com.example.pixa.empty_adaptive',
          candidates: <PixaPluginIntegrationCandidate>[
            PixaPluginIntegrationCandidate.pureDart(
              id: 'dart',
              packageName: 'pixa_empty_adaptive',
              register: (_) {},
            ),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('must register at least one'),
          ),
        ),
      );
      expect(registry.fetchers, isEmpty);
      expect(registry.adaptiveIntegrationSelections, isEmpty);
    },
  );

  test('Pixa.configure accepts adaptive plugins through PixaConfig', () async {
    await Pixa.configure(
      const PixaConfig(
        cacheRootPath: 'unused',
        plugins: <PixaPlugin>[
          _AdaptivePlugin(
            hostRuntimeAvailable: false,
            platformAvailable: false,
          ),
        ],
      ),
    );

    final PixaCompiledRoutePlan routePlan = Pixa.pipeline.routePlan;
    expect(routePlan.adaptiveIntegrations.single.candidateId, 'dart');
    expect(
      routePlan.fetcherForSourceKind('adaptive-source')?.executionKind,
      PixaPluginExecutionKind.dart,
    );
  });

  test(
    'PixaRegistry rejects runtime descriptors without runtime contracts',
    () {
      final PixaRegistry registry = PixaRegistry();

      expect(
        () => registry.registerDecoder(const _BadRuntimeDecoderDescriptor()),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('runtime contract'),
          ),
        ),
      );
    },
  );

  test(
    'PixaRegistry rejects runtime descriptors without zero-copy contract',
    () {
      final PixaRegistry registry = PixaRegistry();

      expect(
        () => registry.registerDecoder(
          const _RuntimeDecoderDescriptor(
            id: 'bad-Runtime-owned-buffer',
            runtime: PixaRuntimeContract.builtInHostModule(
              moduleId: 'bad.runtime.buffer',
              ownedBuffers: false,
            ),
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('owned buffers'),
          ),
        ),
      );
    },
  );

  test('PixaRegistry supports explicit pure Dart plugin descriptors', () {
    final PixaRegistry registry = PixaRegistry()
      ..registerFetcher(const _DartFetcherDescriptor())
      ..registerDecoder(const _DartDecoderDescriptor())
      ..registerProcessor(const _DartProcessorDescriptor())
      ..registerCacheStore(const _DartCacheStoreDescriptor());

    expect(
      registry.fetchers.single.executionKind,
      PixaPluginExecutionKind.dart,
    );
    expect(
      registry.decoders.single.executionKind,
      PixaPluginExecutionKind.dart,
    );
    expect(
      registry.processors.single.executionKind,
      PixaPluginExecutionKind.dart,
    );
    expect(
      registry.cacheStores.single.executionKind,
      PixaPluginExecutionKind.dart,
    );
  });

  test(
    'PixaRegistry rejects platform descriptors without platform contract',
    () {
      final PixaRegistry registry = PixaRegistry();

      expect(
        () => registry.registerFetcher(const _BadPlatformFetcherDescriptor()),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('platform contract'),
          ),
        ),
      );
    },
  );

  test('PixaRegistry architecture snapshot separates plugin runtimes', () {
    final PixaRegistry registry = PixaRegistry()
      ..registerFetcher(
        const _FetcherDescriptor(
          id: 'external-fetcher',
          sourceKinds: <String>{'external-source'},
        ),
      )
      ..registerDecoder(
        const _RuntimeDecoderDescriptor(
          id: 'runtime-decoder',
          runtime: PixaRuntimeContract.hostLinkedPluginModule(
            moduleId: 'third.party.decoder',
            entrypointSymbol: 'pixa_plugin_init_decoder',
            implementationLanguage: 'c',
          ),
        ),
      )
      ..registerProcessor(const _DartProcessorDescriptor());

    final PixaRegistryArchitectureSnapshot snapshot = registry
        .architectureSnapshot();

    expect(snapshot.fetchers, 1);
    expect(snapshot.decoders, 1);
    expect(snapshot.processors, 1);
    expect(snapshot.decoderSignatureRoutes, 0);
    expect(snapshot.decodersWithMetadataProbe, 1);
    expect(snapshot.decodersWithRegionDecode, 0);
    expect(snapshot.decodersWithStreamingInput, 1);
    expect(snapshot.runtimeHandlers, 1);
    expect(snapshot.dartHandlers, 1);
    expect(snapshot.externalHandlers, 1);
    expect(snapshot.runtimeModules, 1);
    expect(snapshot.hostLinkedPluginModules, 1);
    expect(snapshot.linkableRuntimeModules, 1);
    expect(snapshot.runtimeCanUseSingleHostBinary, isTrue);
    expect(snapshot.defaultHotPathUsesRuntimeOnly, isFalse);
    expect(snapshot.toJson()['runtimeCanUseSingleHostBinary'], isTrue);
  });

  test(
    'PixaImage and PixaProvider factories expose plugin execution policy',
    () {
      const PixaPluginExecutionPolicy policy =
          PixaPluginExecutionPolicy.runtimeFirstWithDart();

      final PixaImage image = PixaImage.network(
        'https://images.example.test/a.gif',
        pluginExecutionPolicy: policy,
      );
      final PixaProvider provider = PixaProvider.network(
        'https://images.example.test/a.gif',
        pluginExecutionPolicy: policy,
      );

      expect(image.request.pluginExecutionPolicy, policy);
      expect(provider.request.pluginExecutionPolicy, policy);
    },
  );

  test('PixaRegistry rejects Dart descriptors without Dart handlers', () {
    final PixaRegistry registry = PixaRegistry();

    expect(
      () => registry.registerDecoder(const _BadDartDecoderDescriptor()),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('Dart handler contract'),
        ),
      ),
    );
  });

  test('PixaRegistry rejects conflicting decoder priorities', () {
    final PixaRegistry registry = PixaRegistry();
    registry.registerDecoder(
      const _DecoderDescriptor(
        id: 'first',
        mimeTypes: <String>{'image/x-pixa-test'},
        formatIds: <String>{'pixa-test'},
        priority: 10,
      ),
    );

    expect(
      () => registry.registerDecoder(
        const _DecoderDescriptor(
          id: 'second',
          mimeTypes: <String>{'IMAGE/X-PIXA-TEST'},
          formatIds: <String>{'other-test'},
          priority: 10,
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('already registered'),
        ),
      ),
    );
    expect(
      () => registry.registerDecoder(
        const _DecoderDescriptor(
          id: 'third',
          mimeTypes: <String>{'image/third-test'},
          formatIds: <String>{'PIXA-TEST'},
          priority: 10,
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('already registered'),
        ),
      ),
    );
  });

  test('PixaRegistry selects the highest-priority decoder for a MIME type', () {
    final PixaRegistry registry = PixaRegistry();
    const _DecoderDescriptor low = _DecoderDescriptor(
      id: 'low-test',
      mimeTypes: <String>{'image/x-pixa-test'},
      formatIds: <String>{'pixa-test'},
      priority: 10,
    );
    const _DecoderDescriptor high = _DecoderDescriptor(
      id: 'high-test',
      mimeTypes: <String>{'image/x-pixa-test'},
      formatIds: <String>{'pixa-test'},
      priority: 100,
    );
    registry
      ..registerDecoder(low)
      ..registerDecoder(high);

    expect(registry.decoderForMimeType('IMAGE/X-PIXA-TEST'), high);
    expect(
      registry.decoderForMimeType(' image/x-pixa-test; variant=large '),
      high,
    );
    expect(registry.decoderForFormatId('PIXA-TEST'), high);
    expect(registry.decoderForFormatId(' pixa-test '), high);
    expect(registry.decoderForFormatId('png'), isNull);
    expect(registry.decoderForMimeType('image/png'), isNull);
  });

  test('PixaRegistry routes decoder by bounded signature and capabilities', () {
    final PixaRegistry registry = PixaRegistry();
    const _DecoderDescriptor low = _DecoderDescriptor(
      id: 'low-signature',
      mimeTypes: <String>{},
      priority: 10,
      signatures: <PixaDecoderSignature>[
        PixaDecoderSignature(
          offset: 4,
          magic: <int>[0x66, 0x74, 0x79, 0x70],
          mimeType: 'image/x-signature',
          formatId: 'signature',
        ),
      ],
      capabilities: PixaDecoderCapabilities.runtimeRaster(regionDecode: true),
    );
    const _DecoderDescriptor high = _DecoderDescriptor(
      id: 'high-signature',
      mimeTypes: <String>{},
      priority: 100,
      signatures: <PixaDecoderSignature>[
        PixaDecoderSignature(
          offset: 4,
          magic: <int>[0x66, 0x74, 0x79, 0x70],
          mimeType: 'image/x-signature',
          formatId: 'signature',
        ),
      ],
      capabilities: PixaDecoderCapabilities.runtimeRaster(regionDecode: true),
    );
    registry
      ..registerDecoder(low)
      ..registerDecoder(high);

    final Uint8List payload = Uint8List.fromList(<int>[
      0x00,
      0x00,
      0x00,
      0x00,
      0x66,
      0x74,
      0x79,
      0x70,
    ]);
    expect(registry.decoderForSignature(payload), high);
    expect(registry.decoderForPayload(payload), high);

    final PixaRegistryArchitectureSnapshot snapshot = registry
        .architectureSnapshot();
    expect(snapshot.decoderSignatureRoutes, 2);
    expect(snapshot.decodersWithMetadataProbe, 2);
    expect(snapshot.decodersWithRegionDecode, 2);
    expect(snapshot.decodersWithStreamingInput, 2);
    expect(snapshot.toJson()['decoderSignatureRoutes'], 2);
  });

  test(
    'PixaImageFormatCatalog preserves built-in routes and resolves custom formats',
    () {
      final PixaRegistry registry = PixaRegistry();
      const _DecoderDescriptor builtInConflict = _DecoderDescriptor(
        id: 'conflicting-png',
        mimeTypes: <String>{'image/png'},
        formatIds: <String>{'png'},
        priority: 1000,
      );
      const _RuntimeDecoderDescriptor custom = _RuntimeDecoderDescriptor(
        id: 'custom-runtime-format',
        mimeTypes: <String>{'image/x-pixa-custom'},
        formatIds: <String>{'pixa-custom'},
        priority: 100,
        runtime: PixaRuntimeContract.hostLinkedPluginModule(
          moduleId: 'third.party.custom.decoder',
          entrypointSymbol: 'pixa_plugin_init_custom_decoder',
          implementationLanguage: 'rust',
        ),
        signatures: <PixaDecoderSignature>[
          PixaDecoderSignature(
            offset: 0,
            magic: <int>[0x50, 0x58, 0x43, 0x31],
            mimeType: 'image/x-pixa-custom',
            formatId: 'pixa-custom',
          ),
        ],
        capabilities: PixaDecoderCapabilities.runtimeRaster(
          defaultRuntimeDisplay: true,
          regionDecode: true,
        ),
      );
      registry
        ..registerDecoder(builtInConflict)
        ..registerDecoder(custom);

      final PixaImageFormatCatalog catalog = PixaImageFormatCatalog(
        registry: registry,
      );
      final PixaImageFormatRoute png = catalog.routeForMimeType('image/png')!;
      expect(png.source, PixaImageFormatRouteSource.builtIn);
      expect(png.pluginDecoder, isNull);
      expect(png.formatId, 'png');

      final PixaImageFormatRoute customRoute = catalog.routeForPayload(
        Uint8List.fromList(<int>[0x50, 0x58, 0x43, 0x31, 0x00]),
      )!;
      expect(customRoute.source, PixaImageFormatRouteSource.plugin);
      expect(customRoute.pluginDecoder, custom);
      expect(customRoute.mimeType, 'image/x-pixa-custom');
      expect(customRoute.formatId, 'pixa-custom');
      expect(customRoute.capabilities.metadataProbe, isTrue);
      expect(customRoute.capabilities.staticDecode, isTrue);
      expect(customRoute.capabilities.runtimeDisplay, isTrue);
      expect(customRoute.capabilities.zeroCopyInput, isTrue);
      expect(customRoute.capabilities.ownedOutputBuffers, isTrue);
      expect(customRoute.defaultRuntimeDisplay, isTrue);
      expect(customRoute.regionDecode, isTrue);
    },
  );

  test('PixaRegistry rejects invalid decoder route claims', () {
    final PixaRegistry registry = PixaRegistry();

    expect(
      () => registry.registerDecoder(
        const _DecoderDescriptor(
          id: 'bad-decoder',
          mimeTypes: <String>{' ; variant=large'},
          priority: 10,
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('decoder MIME type'),
        ),
      ),
    );
    expect(
      () => registry.registerDecoder(
        const _DecoderDescriptor(
          id: 'bad-format-decoder',
          mimeTypes: <String>{},
          formatIds: <String>{' '},
          priority: 10,
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('decoder format id'),
        ),
      ),
    );
    expect(
      () => registry.registerDecoder(
        const _DecoderDescriptor(
          id: 'route-less-decoder',
          mimeTypes: <String>{},
          formatIds: <String>{},
          priority: 10,
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('route'),
        ),
      ),
    );
    expect(
      () => registry.registerDecoder(
        const _DecoderDescriptor(
          id: 'bad-signature-decoder',
          mimeTypes: <String>{},
          signatures: <PixaDecoderSignature>[
            PixaDecoderSignature(
              offset: 4096,
              magic: <int>[0x01],
              mimeType: 'image/bad-signature',
            ),
          ],
          priority: 10,
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('4096'),
        ),
      ),
    );
  });

  test('PixaRegistry rejects runtime decoder without hot-path safety', () {
    final PixaRegistry registry = PixaRegistry();

    expect(
      () => registry.registerDecoder(
        const _RuntimeDecoderDescriptor(
          id: 'bad-runtime-copying-decoder',
          runtime: PixaRuntimeContract.builtInHostModule(
            moduleId: 'bad.runtime.copying.decoder',
          ),
          capabilities: PixaDecoderCapabilities.dartBytes(),
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('zero-copy'),
        ),
      ),
    );
  });

  test('PixaRegistry rejects processor and cache store conflicts', () {
    final PixaRegistry registry = PixaRegistry();
    registry
      ..registerProcessor(
        const _ProcessorDescriptor(
          id: 'resize-a',
          operations: <String>{'resize'},
        ),
      )
      ..registerCacheStore(
        const _CacheStoreDescriptor(
          id: 'private-store-a',
          namespace: 'private',
        ),
      );

    expect(
      () => registry.registerProcessor(
        const _ProcessorDescriptor(
          id: 'resize-b',
          operations: <String>{'resize'},
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      () => registry.registerCacheStore(
        const _CacheStoreDescriptor(
          id: 'private-store-b',
          namespace: 'private',
        ),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('PixaRuntimeCacheStoreDescriptor describes the Rust runtime store', () {
    const PixaRuntimeCacheStoreDescriptor descriptor =
        PixaRuntimeCacheStoreDescriptor();

    expect(descriptor.id, pixaCacheStoreDescriptorId);
    expect(descriptor.namespace, pixaCacheStoreNamespace);
    expect(descriptor.engine, PixaCacheStoreEngine.rustRuntime);
    expect(descriptor.capabilities.binaryValues, isTrue);
    expect(descriptor.capabilities.metadataSidecar, isTrue);
    expect(descriptor.capabilities.atomicWrites, isTrue);
    expect(descriptor.capabilities.checksumValidation, isTrue);
    expect(descriptor.capabilities.ttl, isTrue);
    expect(descriptor.capabilities.namespaceIsolation, isTrue);
    expect(descriptor.capabilities.sizeEviction, isTrue);
    expect(descriptor.capabilities.corruptionRecovery, isTrue);
    expect(descriptor.capabilities.concurrentEntryGuards, isTrue);
    expect(descriptor.capabilities.ownedReadBuffers, isTrue);
    expect(descriptor.capabilities.dartStorageRuntime, isFalse);
  });

  test('PixaRegistry exposes the Rust runtime cache store descriptor', () {
    final PixaRegistry registry = PixaRegistry()
      ..registerCacheStore(const PixaRuntimeCacheStoreDescriptor());

    expect(registry.cacheStores, hasLength(1));
    expect(registry.cacheStores.single, isA<PixaRuntimeCacheStoreDescriptor>());
  });
}

void _registerAdaptiveRuntimeFetcher(PixaRegistry registry) {
  registry.registerFetcher(
    const _AdaptiveRuntimeFetcherDescriptor(
      id: 'runtime',
      sourceKinds: <String>{'adaptive-source'},
    ),
  );
}

void _registerAdaptiveRuntimeOnlyConflictFetcher(PixaRegistry registry) {
  registry.registerFetcher(
    const _AdaptiveRuntimeFetcherDescriptor(
      id: 'runtime-conflict',
      sourceKinds: <String>{'runtime-only-adaptive-source'},
    ),
  );
}

void _registerAdaptivePlatformFetcher(PixaRegistry registry) {
  registry.registerFetcher(const _AdaptivePlatformFetcherDescriptor());
}

void _registerAdaptiveDartFetcher(PixaRegistry registry) {
  registry.registerFetcher(const _AdaptiveDartFetcherDescriptor());
}

void _registerAdaptiveExternalFetcher(PixaRegistry registry) {
  registry.registerFetcher(
    const _FetcherDescriptor(
      id: 'external',
      sourceKinds: <String>{'adaptive-source'},
    ),
  );
}

final class _TestPlugin implements PixaPlugin {
  const _TestPlugin({
    required this.id,
    this.compatiblePixaVersions = _compatiblePixa1,
  });

  @override
  final String id;

  @override
  final PixaVersionConstraint compatiblePixaVersions;

  @override
  void register(PixaRegistry registry) {}
}

final class _AdaptivePlugin implements PixaPlugin {
  const _AdaptivePlugin({
    required this.hostRuntimeAvailable,
    required this.platformAvailable,
  });

  final bool hostRuntimeAvailable;
  final bool platformAvailable;

  @override
  String get id => 'com.example.pixa.adaptive';

  @override
  PixaVersionConstraint get compatiblePixaVersions =>
      const PixaVersionConstraint(
        minimumInclusive: '1.0.0',
        maximumExclusive: '2.0.0',
      );

  @override
  void register(PixaRegistry registry) {
    registry.registerAdaptiveIntegration(
      pluginId: id,
      candidates: <PixaPluginIntegrationCandidate>[
        PixaPluginIntegrationCandidate.runtimeHost(
          id: 'runtime',
          packageName: 'pixa_adaptive_example',
          hostRuntimeAvailable: hostRuntimeAvailable,
          register: _registerAdaptiveRuntimeFetcher,
        ),
        PixaPluginIntegrationCandidate.platformChannel(
          id: 'platform',
          packageName: 'pixa_adaptive_example',
          platformAvailable: platformAvailable,
          register: _registerAdaptivePlatformFetcher,
        ),
        PixaPluginIntegrationCandidate.pureDart(
          id: 'dart',
          packageName: 'pixa_adaptive_example',
          register: _registerAdaptiveDartFetcher,
        ),
      ],
    );
  }
}

final class _FetcherDescriptor implements PixaFetcherDescriptor {
  const _FetcherDescriptor({required this.id, required this.sourceKinds});

  @override
  final String id;

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.external;

  @override
  final Set<String> sourceKinds;
}

final class _DecoderDescriptor implements PixaDecoderDescriptor {
  const _DecoderDescriptor({
    required this.id,
    required this.mimeTypes,
    required this.priority,
    this.formatIds = const <String>{},
    this.signatures = const <PixaDecoderSignature>[],
    this.capabilities = const PixaDecoderCapabilities.runtimeRaster(),
  });

  @override
  final String id;

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.external;

  @override
  final Set<String> mimeTypes;

  @override
  final Set<String> formatIds;

  @override
  final List<PixaDecoderSignature> signatures;

  @override
  final PixaDecoderCapabilities capabilities;

  @override
  final int priority;
}

final class _ProcessorDescriptor implements PixaProcessorDescriptor {
  const _ProcessorDescriptor({required this.id, required this.operations});

  @override
  final String id;

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.external;

  @override
  final Set<String> operations;
}

final class _CacheStoreDescriptor implements PixaCacheStoreDescriptor {
  const _CacheStoreDescriptor({required this.id, required this.namespace});

  @override
  final String id;

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.external;

  @override
  final String namespace;
}

final class _BadRuntimeDecoderDescriptor implements PixaDecoderDescriptor {
  const _BadRuntimeDecoderDescriptor();

  @override
  String get id => 'bad-runtime';

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.runtime;

  @override
  Set<String> get mimeTypes => const <String>{'image/example'};

  @override
  Set<String> get formatIds => const <String>{};

  @override
  List<PixaDecoderSignature> get signatures => const <PixaDecoderSignature>[];

  @override
  PixaDecoderCapabilities get capabilities =>
      const PixaDecoderCapabilities.runtimeRaster();

  @override
  int get priority => 1;
}

final class _BadDartDecoderDescriptor implements PixaDecoderDescriptor {
  const _BadDartDecoderDescriptor();

  @override
  String get id => 'bad-dart';

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.dart;

  @override
  Set<String> get mimeTypes => const <String>{'image/bad-dart'};

  @override
  Set<String> get formatIds => const <String>{};

  @override
  List<PixaDecoderSignature> get signatures => const <PixaDecoderSignature>[];

  @override
  PixaDecoderCapabilities get capabilities =>
      const PixaDecoderCapabilities.dartBytes();

  @override
  int get priority => 1;
}

final class _RuntimeDecoderDescriptor
    implements PixaDecoderDescriptor, PixaRuntimeDescriptor {
  const _RuntimeDecoderDescriptor({
    required this.id,
    required this.runtime,
    Set<String>? mimeTypes,
    Set<String>? formatIds,
    List<PixaDecoderSignature>? signatures,
    int priority = 10,
    this.capabilities = const PixaDecoderCapabilities.runtimeRaster(),
  }) : _mimeTypes = mimeTypes,
       _formatIds = formatIds,
       _signatures = signatures,
       _priority = priority;

  @override
  final String id;

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.runtime;

  @override
  Set<String> get mimeTypes => _mimeTypes ?? <String>{'image/$id'};

  @override
  Set<String> get formatIds => _formatIds ?? <String>{id};

  @override
  List<PixaDecoderSignature> get signatures =>
      _signatures ?? const <PixaDecoderSignature>[];

  @override
  final PixaDecoderCapabilities capabilities;

  @override
  int get priority => _priority;

  @override
  final PixaRuntimeContract runtime;

  final Set<String>? _mimeTypes;
  final Set<String>? _formatIds;
  final List<PixaDecoderSignature>? _signatures;
  final int _priority;
}

final class _AdaptiveRuntimeFetcherDescriptor
    implements PixaFetcherDescriptor, PixaRuntimeDescriptor {
  const _AdaptiveRuntimeFetcherDescriptor({
    required this.id,
    required this.sourceKinds,
  });

  @override
  final String id;

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.runtime;

  @override
  final Set<String> sourceKinds;

  @override
  PixaRuntimeContract get runtime => PixaRuntimeContract.hostLinkedPluginModule(
    moduleId: 'com.example.pixa.$id',
    packageName: 'pixa_adaptive_example',
    implementationLanguage: 'rust',
    entrypointSymbol: 'pixa_${id.replaceAll('-', '_')}_plugin_init',
  );
}

final class _AdaptivePlatformFetcherDescriptor
    implements PixaPlatformFetcherDescriptor {
  const _AdaptivePlatformFetcherDescriptor();

  @override
  String get id => 'platform';

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.platform;

  @override
  Set<String> get sourceKinds => const <String>{'adaptive-source'};

  @override
  PixaPlatformContract get platform => const PixaPlatformContract(
    channel: 'dev.pixa/adaptive_fetcher',
    supportedPlatforms: <PixaHostPlatform>{
      PixaHostPlatform.android,
      PixaHostPlatform.ios,
    },
    maxConcurrentCalls: 2,
    supportsCancellation: true,
    hotPathSafe: false,
  );

  @override
  PixaFetcher get fetcher => const _NoopFetcher();
}

final class _AdaptiveDartFetcherDescriptor
    implements PixaDartFetcherDescriptor {
  const _AdaptiveDartFetcherDescriptor();

  @override
  String get id => 'dart';

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.dart;

  @override
  Set<String> get sourceKinds => const <String>{'adaptive-source'};

  @override
  PixaFetcher get fetcher => const _NoopFetcher();
}

final class _DartFetcherDescriptor implements PixaDartFetcherDescriptor {
  const _DartFetcherDescriptor();

  @override
  String get id => 'dart-fetcher';

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.dart;

  @override
  Set<String> get sourceKinds => const <String>{'dart-source'};

  @override
  PixaFetcher get fetcher => const _NoopFetcher();
}

final class _DartDecoderDescriptor implements PixaDartDecoderDescriptor {
  const _DartDecoderDescriptor();

  @override
  String get id => 'dart-decoder';

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.dart;

  @override
  Set<String> get mimeTypes => const <String>{'image/dart'};

  @override
  Set<String> get formatIds => const <String>{};

  @override
  List<PixaDecoderSignature> get signatures => const <PixaDecoderSignature>[];

  @override
  PixaDecoderCapabilities get capabilities =>
      const PixaDecoderCapabilities.dartBytes();

  @override
  int get priority => 1;

  @override
  PixaDecoder get decoder => const _NoopDecoder();
}

final class _DartProcessorDescriptor implements PixaDartProcessorDescriptor {
  const _DartProcessorDescriptor();

  @override
  String get id => 'dart-processor';

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.dart;

  @override
  Set<String> get operations => const <String>{'dart-process'};

  @override
  PixaProcessor get processor => const _NoopProcessor();
}

final class _DartCacheStoreDescriptor implements PixaDartCacheStoreDescriptor {
  const _DartCacheStoreDescriptor();

  @override
  String get id => 'dart-cache-store';

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.dart;

  @override
  String get namespace => 'dart-cache';

  @override
  PixaCacheStore get cacheStore => const _NoopCacheStore();
}

final class _PlatformFetcherDescriptor
    implements PixaPlatformFetcherDescriptor {
  const _PlatformFetcherDescriptor();

  @override
  String get id => 'platform-fetcher';

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.platform;

  @override
  Set<String> get sourceKinds => const <String>{'platform-source'};

  @override
  PixaPlatformContract get platform => const PixaPlatformContract(
    channel: 'dev.pixa/platform_fetcher',
    supportedPlatforms: <PixaHostPlatform>{PixaHostPlatform.android},
    maxConcurrentCalls: 2,
    supportsCancellation: true,
    hotPathSafe: false,
  );

  @override
  PixaFetcher get fetcher => const _NoopFetcher();
}

final class _BadPlatformFetcherDescriptor implements PixaFetcherDescriptor {
  const _BadPlatformFetcherDescriptor();

  @override
  String get id => 'bad-platform-fetcher';

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.platform;

  @override
  Set<String> get sourceKinds => const <String>{'bad-platform-source'};
}

final class _NoopFetcher implements PixaFetcher {
  const _NoopFetcher();

  @override
  PixaBytePayload fetch(PixaSource source, PixaExecutionContext context) {
    throw UnsupportedError('noop fetcher is registry-only');
  }
}

final class _NoopDecoder implements PixaDecoder {
  const _NoopDecoder();

  @override
  PixaBytePayload decode(PixaBytePayload input, PixaExecutionContext context) {
    return input;
  }
}

final class _NoopProcessor implements PixaProcessor {
  const _NoopProcessor();

  @override
  PixaBytePayload process(PixaBytePayload input, PixaProcessorContext context) {
    return input;
  }
}

final class _NoopCacheStore implements PixaCacheStore {
  const _NoopCacheStore();

  @override
  PixaCacheLookup read(
    String namespace,
    String key,
    PixaExecutionContext context,
  ) {
    return const PixaCacheMiss();
  }

  @override
  void write(
    String namespace,
    String key,
    PixaBytePayload payload,
    PixaCacheWriteContext context,
  ) {}

  @override
  void remove(String namespace, String key) {}

  @override
  void clearNamespace(String namespace) {}
}
