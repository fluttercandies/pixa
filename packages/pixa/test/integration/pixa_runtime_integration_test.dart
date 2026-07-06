import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('runtime pipeline loads bytes and reports platform self-check',
      () async {
    final Directory cacheRoot =
        await Directory.systemTemp.createTemp('pixa-integration-runtime-');
    addTearDown(() {
      if (cacheRoot.existsSync()) {
        cacheRoot.deleteSync(recursive: true);
      }
    });
    await Pixa.configure(PixaConfig(cacheRootPath: cacheRoot.path));

    final PixaPipelineLoad load = await Pixa.pipeline.load(PixaRequest(
      source: PixaSource.bytes(_minimalGif(), id: 'integration-runtime-gif'),
      cachePolicy: const PixaCachePolicy.noStore(),
      decoderOptions: const <String, Object?>{'displayBackend': 'runtime'},
    ));
    addTearDown(load.dispose);

    final image = load.decodeRuntimeRgba(
      maxDecodedPixels: 1,
      maxOutputBytes: 4,
    );
    addTearDown(image.dispose);

    expect(image.width, 1);
    expect(image.height, 1);
    expect(image.rowBytes, 4);
    expect(image.bytes, <int>[255, 255, 255, 255]);

    final PixaDebugSnapshot snapshot = PixaDebugInspector.snapshot();
    expect(snapshot.isConfigured, isTrue);
    expect(snapshot.platformSelfCheck.isSupportedPlatform, isTrue);
    expect(snapshot.platformSelfCheck.passed, isTrue);
    expect(
      snapshot.platformSelfCheck.checks
          .where((PixaRuntimePlatformCheck check) => check.required)
          .every((PixaRuntimePlatformCheck check) => check.passed),
      isTrue,
    );
  });
}

Uint8List _minimalGif() {
  return Uint8List.fromList(<int>[
    0x47,
    0x49,
    0x46,
    0x38,
    0x39,
    0x61,
    0x01,
    0x00,
    0x01,
    0x00,
    0x80,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0xff,
    0xff,
    0xff,
    0x2c,
    0x00,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x01,
    0x00,
    0x00,
    0x02,
    0x02,
    0x4c,
    0x01,
    0x00,
    0x3b,
  ]);
}
