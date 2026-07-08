import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/src/image_analysis.dart'
    show decodeRuntimeImageAnalysisForTest;

void main() {
  test('PixaImageAnalysis decodes runtime binary payload', () {
    final Uint8List payload = Uint8List.fromList(<int>[
      0x50,
      0x58,
      0x41,
      0x31,
      0x0a,
      0x00,
      0x00,
      0x00,
      0x14,
      0x00,
      0x00,
      0x00,
      0xff,
      0x11,
      0x22,
      0x33,
      0xff,
      0x44,
      0x55,
      0x66,
      0x02,
      0xff,
      0x11,
      0x22,
      0x33,
      0xff,
      0x44,
      0x55,
      0x66,
    ]);

    final PixaImageAnalysis analysis = decodeRuntimeImageAnalysisForTest(
      payload,
    );

    expect(analysis.width, 10);
    expect(analysis.height, 20);
    expect(analysis.averageArgb, 0xff112233);
    expect(analysis.dominantArgb, 0xff445566);
    expect(analysis.paletteArgb, <int>[0xff112233, 0xff445566]);
  });

  test('PixaImageAnalysis rejects malformed runtime payloads', () {
    expect(
      () => decodeRuntimeImageAnalysisForTest(Uint8List.fromList(<int>[1, 2])),
      throwsFormatException,
    );
  });

  test('PixaImageAnalysis parses encoded bytes through runtime', () {
    final PixaImageAnalysis analysis = PixaImageAnalysis.parseEncoded(
      _rgbaPng2x2(),
    );

    expect(analysis.width, 2);
    expect(analysis.height, 2);
    expect(analysis.paletteArgb, isNotEmpty);
    expect(analysis.averageArgb >> 24, 0xff);
  });
}

Uint8List _rgbaPng2x2() {
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
