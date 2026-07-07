import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../hook/plugin_plan.dart';

void main() {
  test('runtime plugin plan loads built-in host modules', () {
    final PixaRuntimePluginBuildPlan plan = PixaRuntimePluginBuildPlan.load(
      coreManifest: Directory.current.uri.resolve('plugins/pixa_plugins.json'),
    );

    expect(plan.modules, hasLength(3));
    expect(plan.builtInHostModules, 2);
    expect(plan.hostLinkedPluginModules, 1);
    expect(plan.assetModules, 0);
    expect(plan.linkableModules, 3);
    expect(plan.canUseSingleHostBinary, isTrue);
    expect(
      plan.modules.map((PixaRuntimePluginModulePlan module) => module.moduleId),
      containsAll(<String>[
        'pixa.cache_store',
        'pixa.fetcher.s3',
        'pixa.decoder.qoi',
      ]),
    );
    final PixaRuntimePluginModulePlan decoder = plan.modules.singleWhere(
      (PixaRuntimePluginModulePlan module) =>
          module.moduleId == 'pixa.decoder.qoi',
    );
    expect(decoder.decoderFormatIds, isEmpty);
    expect(decoder.decoderMimeTypes, <String>['image/qoi', 'image/x-qoi']);
    expect(decoder.decoderSignatures, isEmpty);
    expect(decoder.decoderCapabilities.defaultRuntimeDisplay, isTrue);
    expect(decoder.decoderCapabilities.hotPathSafe, isTrue);
    expect(decoder.entrypointSymbol, 'pixa_qoi_decoder_plugin_init');
  });

  test('runtime plugin plan accepts explicit host-linked modules', () {
    final PixaRuntimePluginBuildPlan plan =
        PixaRuntimePluginBuildPlan.fromManifestMaps(<Map<String, Object?>>[
          _manifest(<Map<String, Object?>>[
            <String, Object?>{
              'moduleId': 'third.party.decoder',
              'deployment': 'hostLinkedPluginModule',
              'entrypointSymbol': 'pixa_plugin_init_decoder',
              'implementationLanguage': 'c',
              'capabilities': <String>['decoder'],
              'decoderFormatIds': <String>['third-party'],
              'decoderMimeTypes': <String>['image/third-party'],
              'decoderCapabilities': <String, Object?>{
                'metadataProbe': true,
                'staticDecode': true,
                'regionDecode': true,
                'zeroCopyInput': true,
                'ownedOutputBuffers': true,
                'stable': true,
              },
              'link': <String, Object?>{
                'searchPaths': <String>['runtime/lib'],
                'staticLibraries': <String>['third_party_decoder'],
                'frameworks': <String>['ImageIO'],
                'linkArgs': <String>['-Wl,--gc-sections'],
              },
            },
          ]),
        ]);

    expect(plan.modules.single.moduleId, 'third.party.decoder');
    expect(plan.modules.single.decoderFormatIds, <String>['third-party']);
    expect(plan.modules.single.link.staticLibraries, <String>[
      'third_party_decoder',
    ]);
    expect(plan.modules.single.toJson()['link'], isA<Map<String, Object?>>());
    expect(plan.modules.single.toJson()['decoderFormatIds'], <String>[
      'third-party',
    ]);
    expect(
      (plan.modules.single.toJson()['decoderCapabilities']!
          as Map<String, Object?>)['regionDecode'],
      isTrue,
    );
    expect(plan.hostLinkedPluginModules, 1);
    expect(plan.canUseSingleHostBinary, isTrue);
    expect(plan.toJson()['stats'], isA<Map<String, Object?>>());
  });

  test('runtime plugin plan accepts format-specific processor routes', () {
    final PixaRuntimePluginBuildPlan plan =
        PixaRuntimePluginBuildPlan.fromManifestMaps(<Map<String, Object?>>[
          _manifest(<Map<String, Object?>>[
            <String, Object?>{
              'moduleId': 'pixa.processor.jpeg_roi',
              'deployment': 'hostLinkedPluginModule',
              'entrypointSymbol': 'pixa_jpeg_roi_init',
              'implementationLanguage': 'rust',
              'capabilities': <String>['processor'],
              'processorOperations': <String>['tile:jpeg'],
              'link': <String, Object?>{
                'staticLibraries': <String>['pixa_jpeg_roi'],
              },
            },
          ]),
        ]);

    expect(plan.modules.single.processorOperations, <String>{'tile:jpeg'});
    expect(plan.modules.single.toJson()['processorOperations'], <String>[
      'tile:jpeg',
    ]);
    expect(plan.hostLinkedPluginModules, 1);
    expect(plan.canUseSingleHostBinary, isTrue);
  });

  test('runtime plugin plan requires video-frame output MIME contract', () {
    final PixaRuntimePluginBuildPlan plan =
        PixaRuntimePluginBuildPlan.fromManifestMaps(<Map<String, Object?>>[
          _manifest(<Map<String, Object?>>[
            <String, Object?>{
              'moduleId': 'pixa.video_frame.platform',
              'deployment': 'hostLinkedPluginModule',
              'entrypointSymbol': 'pixa_platform_video_frame_plugin_init',
              'implementationLanguage': 'swift/kotlin/c++',
              'capabilities': <String>['fetcher'],
              'fetcherSourceKinds': <String>['video-frame:platform'],
              'videoFrameOutputMimeTypes': <String>['image/png'],
              'videoFrameExact': true,
            },
          ]),
        ]);

    expect(plan.modules.single.fetcherSourceKinds, <String>{
      'video-frame:platform',
    });
    expect(plan.modules.single.videoFrameOutputMimeTypes, <String>{
      'image/png',
    });
    expect(plan.modules.single.videoFrameExact, isTrue);
    expect(plan.modules.single.toJson()['videoFrameOutputMimeTypes'], <String>[
      'image/png',
    ]);

    expect(
      () => PixaRuntimePluginBuildPlan.fromManifestMaps(<Map<String, Object?>>[
        _manifest(<Map<String, Object?>>[
          <String, Object?>{
            'moduleId': 'bad.video_frame',
            'deployment': 'builtInHostModule',
            'capabilities': <String>['fetcher'],
            'fetcherSourceKinds': <String>['video-frame:bad'],
          },
        ]),
      ]),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('video-frame output MIME'),
        ),
      ),
    );
  });

  test(
    'runtime plugin plan accepts built-in video-frame output MIME aliases',
    () {
      final PixaRuntimePluginBuildPlan plan =
          PixaRuntimePluginBuildPlan.fromManifestMaps(<Map<String, Object?>>[
            _manifest(<Map<String, Object?>>[
              <String, Object?>{
                'moduleId': 'pixa.video_frame.aliases',
                'deployment': 'hostLinkedPluginModule',
                'entrypointSymbol': 'pixa_video_frame_alias_plugin_init',
                'implementationLanguage': 'rust',
                'capabilities': <String>['fetcher'],
                'fetcherSourceKinds': <String>['video-frame:aliases'],
                'videoFrameOutputMimeTypes': <String>[
                  'image/x-portable-arbitrarymap',
                  'image/tga',
                  'application/x-tga',
                  'image/vnd-ms.dds',
                  'image/x-dds',
                  'image/x-hdr',
                  'image/hdr',
                ],
                'videoFrameNearest': true,
              },
            ]),
          ]);

      expect(
        plan.modules.single.videoFrameOutputMimeTypes,
        contains('image/tga'),
      );
      expect(
        plan.modules.single.videoFrameOutputMimeTypes,
        contains('image/hdr'),
      );
      expect(plan.modules.single.videoFrameNearest, isTrue);
    },
  );

  test('runtime plugin plan loads official optional native modules', () {
    final PixaRuntimePluginBuildPlan plan = PixaRuntimePluginBuildPlan.load(
      coreManifest: Directory.current.uri.resolve('plugins/pixa_plugins.json'),
      additionalManifests: <Uri>[
        Directory.current.uri.resolve(
          'plugins/optional/pixa_jpeg_turbo_processor.json',
        ),
        Directory.current.uri.resolve(
          'plugins/optional/pixa_webp_processor.json',
        ),
        Directory.current.uri.resolve(
          'plugins/optional/pixa_mjpeg_video_frame.json',
        ),
      ],
    );

    expect(plan.modules, hasLength(6));
    expect(plan.hostLinkedPluginModules, 4);
    expect(plan.canUseSingleHostBinary, isTrue);

    final PixaRuntimePluginModulePlan jpeg = plan.modules.singleWhere(
      (PixaRuntimePluginModulePlan module) =>
          module.moduleId == 'pixa.processor.jpeg_turbo',
    );
    expect(jpeg.entrypointSymbol, 'pixa_jpeg_turbo_processor_plugin_init');
    expect(jpeg.processorOperations, <String>{'tile:jpeg'});
    expect(jpeg.capabilities, <String>{'processor'});
    expect(jpeg.link.isNotEmpty, isFalse);

    final PixaRuntimePluginModulePlan webp = plan.modules.singleWhere(
      (PixaRuntimePluginModulePlan module) =>
          module.moduleId == 'pixa.processor.webp',
    );
    expect(webp.entrypointSymbol, 'pixa_webp_processor_plugin_init');
    expect(webp.processorOperations, <String>{'tile:webp'});
    expect(webp.capabilities, <String>{'processor'});
    expect(webp.link.isNotEmpty, isFalse);

    final PixaRuntimePluginModulePlan mjpeg = plan.modules.singleWhere(
      (PixaRuntimePluginModulePlan module) =>
          module.moduleId == 'pixa.video_frame.mjpeg',
    );
    expect(mjpeg.entrypointSymbol, 'pixa_mjpeg_video_frame_plugin_init');
    expect(mjpeg.fetcherSourceKinds, <String>{'video-frame:mjpeg'});
    expect(mjpeg.videoFrameOutputMimeTypes, <String>{'image/jpeg'});
    expect(mjpeg.videoFrameNearest, isTrue);
    expect(mjpeg.videoFrameExact, isFalse);
    expect(mjpeg.capabilities, <String>{'fetcher'});
    expect(mjpeg.link.isNotEmpty, isFalse);
  });

  test('runtime plugin plan accepts decoder signature routes', () {
    final PixaRuntimePluginBuildPlan plan =
        PixaRuntimePluginBuildPlan.fromManifestMaps(<Map<String, Object?>>[
          _manifest(<Map<String, Object?>>[
            <String, Object?>{
              'moduleId': 'third.party.signature.decoder',
              'deployment': 'hostLinkedPluginModule',
              'entrypointSymbol': 'pixa_plugin_init_decoder',
              'implementationLanguage': 'c',
              'capabilities': <String>['decoder'],
              'decoderSignatures': <Map<String, Object?>>[
                <String, Object?>{
                  'offset': 4,
                  'magicHex': '66 74 79 70 78 79 7A',
                  'mimeType': 'image/third-party',
                  'formatId': 'third-party',
                },
              ],
            },
          ]),
        ]);

    final PixaRuntimeDecoderSignaturePlan signature =
        plan.modules.single.decoderSignatures.single;
    expect(signature.offset, 4);
    expect(signature.magicHex, '6674797078797a');
    expect(signature.mimeType, 'image/third-party');
    expect(signature.formatId, 'third-party');
    expect(
      plan.modules.single.toJson()['decoderSignatures'],
      <Map<String, Object?>>[
        <String, Object?>{
          'offset': 4,
          'magicHex': '6674797078797a',
          'mimeType': 'image/third-party',
          'formatId': 'third-party',
        },
      ],
    );
    expect(plan.modules.single.decoderCapabilities.zeroCopyInput, isTrue);
  });

  test(
    'runtime plugin plan scans user manifest directory deterministically',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'pixa-plugin-plan-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final Directory userDirectory = Directory.fromUri(
        temp.uri.resolve('user/'),
      )..createSync();
      File.fromUri(userDirectory.uri.resolve('b.json')).writeAsStringSync(
        _manifestText(moduleId: 'third.party.b', capability: 'processor'),
      );
      File.fromUri(userDirectory.uri.resolve('a.json')).writeAsStringSync(
        _manifestText(
          moduleId: 'third.party.a',
          capability: 'fetcher',
          linkSearchPath: 'runtime/lib',
        ),
      );
      final File core = File.fromUri(temp.uri.resolve('core.json'))
        ..writeAsStringSync('{"schema":1,"modules":[]}');

      final PixaRuntimePluginBuildPlan plan = PixaRuntimePluginBuildPlan.load(
        coreManifest: core.uri,
        userManifestDirectory: userDirectory.uri,
      );

      expect(
        plan.modules.map(
          (PixaRuntimePluginModulePlan module) => module.moduleId,
        ),
        <String>['third.party.a', 'third.party.b'],
      );
      expect(plan.modules.first.link.searchPaths, <String>[
        userDirectory.uri.resolve('runtime/lib').toFilePath(),
      ]);
      expect(plan.dependencies, hasLength(3));
    },
  );

  test('runtime plugin plan rejects unsafe or ambiguous modules', () {
    expect(
      () => PixaRuntimePluginBuildPlan.fromManifestMaps(<Map<String, Object?>>[
        _manifest(<Map<String, Object?>>[
          _module('bad.buffers', ownedBuffers: false),
        ]),
      ]),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('owned buffers'),
        ),
      ),
    );
    expect(
      () => PixaRuntimePluginBuildPlan.fromManifestMaps(<Map<String, Object?>>[
        _manifest(<Map<String, Object?>>[
          _module('bad.external', deployment: 'external'),
        ]),
      ]),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('deployment'),
        ),
      ),
    );
    expect(
      () => PixaRuntimePluginBuildPlan.fromManifestMaps(<Map<String, Object?>>[
        _manifest(<Map<String, Object?>>[
          _module('dup.module'),
          _module('dup.module'),
        ]),
      ]),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('Duplicate'),
        ),
      ),
    );
    expect(
      () => PixaRuntimePluginBuildPlan.fromManifestMaps(<Map<String, Object?>>[
        _manifest(<Map<String, Object?>>[
          <String, Object?>{
            ..._module('bad.link'),
            'link': <String, Object?>{
              'staticLibraries': <String>['bad\nname'],
            },
          },
        ]),
      ]),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('link.staticLibraries'),
        ),
      ),
    );
    expect(
      () => PixaRuntimePluginBuildPlan.fromManifestMaps(<Map<String, Object?>>[
        _manifest(<Map<String, Object?>>[
          _module('dup.route.a'),
          _module('dup.route.b'),
        ]),
      ]),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('Duplicate Pixa runtime plugin decoder MIME type'),
        ),
      ),
    );
    expect(
      () => PixaRuntimePluginBuildPlan.fromManifestMaps(<Map<String, Object?>>[
        _manifest(<Map<String, Object?>>[
          _module(
            'dup.format.a',
            decoderMimeType: 'image/a',
            decoderFormatIds: <String>{'third-party'},
          ),
          _module(
            'dup.format.b',
            decoderMimeType: 'image/b',
            decoderFormatIds: <String>{'THIRD-PARTY'},
          ),
        ]),
      ]),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('Duplicate Pixa runtime plugin decoder format id'),
        ),
      ),
    );
    expect(
      () => PixaRuntimePluginBuildPlan.fromManifestMaps(<Map<String, Object?>>[
        _manifest(<Map<String, Object?>>[
          _module(
            'dup.signature.a',
            decoderMimeType: 'image/a',
            decoderSignatures: <Map<String, Object?>>[
              <String, Object?>{
                'offset': 4,
                'magicHex': 'CA FE BA BE',
                'mimeType': 'image/a',
              },
            ],
          ),
          _module(
            'dup.signature.b',
            decoderMimeType: 'image/b',
            decoderSignatures: <Map<String, Object?>>[
              <String, Object?>{
                'offset': 4,
                'magicHex': 'cafebabe',
                'mimeType': 'image/b',
              },
            ],
          ),
        ]),
      ]),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('Duplicate Pixa runtime plugin decoder signature'),
        ),
      ),
    );
    expect(
      () => PixaRuntimePluginBuildPlan.fromManifestMaps(<Map<String, Object?>>[
        _manifest(<Map<String, Object?>>[
          <String, Object?>{
            ..._module('bad.decoder.capabilities'),
            'decoderCapabilities': <String, Object?>{'zeroCopyInput': false},
          },
        ]),
      ]),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('zero-copy'),
        ),
      ),
    );
  });
}

Map<String, Object?> _manifest(List<Map<String, Object?>> modules) {
  return <String, Object?>{'schema': 1, 'modules': modules};
}

Map<String, Object?> _module(
  String moduleId, {
  String deployment = 'builtInHostModule',
  bool ownedBuffers = true,
  String decoderMimeType = 'image/test',
  Set<String> decoderFormatIds = const <String>{},
  List<Map<String, Object?>> decoderSignatures = const <Map<String, Object?>>[],
}) {
  return <String, Object?>{
    'moduleId': moduleId,
    'deployment': deployment,
    'capabilities': <String>['decoder'],
    'decoderMimeTypes': <String>[decoderMimeType],
    if (decoderFormatIds.isNotEmpty)
      'decoderFormatIds': decoderFormatIds.toList(),
    if (decoderSignatures.isNotEmpty) 'decoderSignatures': decoderSignatures,
    'ownedBuffers': ownedBuffers,
  };
}

String _manifestText({
  required String moduleId,
  required String capability,
  String? linkSearchPath,
}) {
  final String link = linkSearchPath == null
      ? ''
      : '''
,
      "link": {
        "searchPaths": ["$linkSearchPath"],
        "staticLibraries": ["third_party_plugin"]
      }
''';
  return '''
{
  "schema": 1,
  "modules": [
    {
      "moduleId": "$moduleId",
      "deployment": "hostLinkedPluginModule",
      "entrypointSymbol": "pixa_plugin_init",
      "capabilities": ["$capability"],
      "${_routeField(capability)}": ["${_routeClaim(capability)}"]$link
    }
  ]
}
''';
}

String _routeField(String capability) {
  return switch (capability) {
    'fetcher' => 'fetcherSourceKinds',
    'processor' => 'processorOperations',
    'cacheStore' => 'cacheStoreNamespaces',
    _ => 'decoderMimeTypes',
  };
}

String _routeClaim(String capability) {
  return switch (capability) {
    'fetcher' => 'test-source',
    'processor' => 'testProcessor',
    'cacheStore' => 'test-namespace',
    _ => 'image/test',
  };
}
