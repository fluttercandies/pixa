import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/src/runtime/runtime_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('runtime RGBA decode matches Flutter engine pixels for static PNG',
      () async {
    final Uint8List bytes = _rgbaPng();
    final PixaPipelineLoad load = await PixaPipeline(cacheRootPath: '').load(
      PixaRequest(
        source: PixaSource.bytes(bytes, id: 'pixel-parity-png'),
        cachePolicy: const PixaCachePolicy.noStore(),
      ),
    );
    addTearDown(load.dispose);

    final PixaRuntimeRgbaImage runtime = load.decodeRuntimeRgba(
      maxDecodedPixels: 4,
      maxOutputBytes: 16,
    );
    addTearDown(runtime.dispose);
    final Uint8List engine = await _engineRgba(bytes);

    expect(runtime.width, 2);
    expect(runtime.height, 2);
    expect(runtime.bytes, engine);
  });

  test('runtime processor variants produce isolated output pixels', () async {
    final Uint8List bytes = _rgbaPng();
    final PixaPipeline pipeline = PixaPipeline(cacheRootPath: '');
    final PixaRequest greenCrop = PixaRequest(
      source: PixaSource.bytes(bytes, id: 'processor-pixel-source'),
      cachePolicy: const PixaCachePolicy.noStore(),
      processors: const <String>['crop(x=1,y=0,width=1,height=1)'],
    );
    final PixaRequest blueCrop = greenCrop.copyWith(
      processors: const <String>['crop(x=0,y=1,width=1,height=1)'],
    );

    final PixaPipelineLoad greenLoad = await pipeline.load(greenCrop);
    final PixaPipelineLoad blueLoad = await pipeline.load(blueCrop);
    addTearDown(greenLoad.dispose);
    addTearDown(blueLoad.dispose);
    final PixaRuntimeRgbaImage green = greenLoad.decodeRuntimeRgba(
      maxDecodedPixels: 1,
      maxOutputBytes: 4,
    );
    final PixaRuntimeRgbaImage blue = blueLoad.decodeRuntimeRgba(
      maxDecodedPixels: 1,
      maxOutputBytes: 4,
    );
    addTearDown(green.dispose);
    addTearDown(blue.dispose);

    expect(greenCrop.cacheKey, isNot(blueCrop.cacheKey));
    expect(green.bytes, <int>[0, 255, 0, 255]);
    expect(blue.bytes, <int>[0, 0, 255, 255]);
  });

  test('runtime resize processor preserves expected RGBA pixels', () async {
    final Uint8List bytes = _rgbaPng();
    final PixaPipelineLoad load = await PixaPipeline(cacheRootPath: '').load(
      PixaRequest(
        source: PixaSource.bytes(bytes, id: 'resize-pixel-source'),
        cachePolicy: const PixaCachePolicy.noStore(),
        processors: const <String>[
          'resize(width=2,height=2,mode=exact,filter=nearest)',
        ],
      ),
    );
    addTearDown(load.dispose);
    final PixaRuntimeRgbaImage resized = load.decodeRuntimeRgba(
      maxDecodedPixels: 4,
      maxOutputBytes: 16,
    );
    addTearDown(resized.dispose);

    expect(resized.width, 2);
    expect(resized.height, 2);
    expect(resized.bytes, await _engineRgba(bytes));
  });

  test('Flutter engine animated GIF first frame remains red', () async {
    final ui.Codec codec = await ui.instantiateImageCodec(_animatedGif());
    addTearDown(codec.dispose);

    final ui.FrameInfo frame = await codec.getNextFrame();
    addTearDown(frame.image.dispose);
    final ByteData data = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ) ??
        (throw StateError('Failed to read first frame pixels.'));

    expect(codec.frameCount, 2);
    expect(data.buffer.asUint8List(), <int>[255, 0, 0, 255]);
  });
}

Future<Uint8List> _engineRgba(Uint8List bytes) async {
  final ui.Codec codec = await ui.instantiateImageCodec(bytes);
  try {
    final ui.FrameInfo frame = await codec.getNextFrame();
    try {
      final ByteData data = await frame.image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ) ??
          (throw StateError('Failed to read engine pixels.'));
      return data.buffer.asUint8List();
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

Uint8List _rgbaPng() {
  return base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAIGNIUk0AAHomAACAhAAA'
    '+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGYktHRAD/AP8A/6C9p5MAAAAHdE'
    'lNRQfqBwUNOy2PQJ54AAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTA3LTA1VDEzOjU5'
    'OjQ1KzAwOjAwNf9BQgAAACV0RVh0ZGF0ZTptb2RpZnkAMjAyNi0wNy0wNVQxMzo1O'
    'To0NSswMDowMESi+f4AAAAodEVYdGRhdGU6dGltZXN0YW1wADIwMjYtMDctMDVUMT'
    'M6NTk6NDUrMDA6MDATt9ghAAAAGElEQVQI1wXBAQEAAAjDIG7/zhNE0k3CAz7tBf'
    '6rMU13AAAAAElFTkSuQmCC',
  );
}

Uint8List _animatedGif() {
  return base64Decode(
    'R0lGODlhAQABAPAAAP8AAP///yH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAA'
    'AAAQABAAACAkQBACH5BAAKAAAALAAAAAABAAEAgAAA/////wICRAEAOw==',
  );
}
