import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

void main() {
  test('parses progressive JPEG metadata from encoded headers', () {
    final PixaImageMetadata metadata = PixaImageMetadata.parseEncoded(
      _jpegWithSof(0xc2, 4096, 2048),
    );

    expect(metadata.width, 4096);
    expect(metadata.height, 2048);
    expect(metadata.format, PixaImageMetadataFormat.jpeg);
    expect(metadata.isProgressive, isTrue);
    expect(metadata.isAnimated, isFalse);
    expect(metadata.size, const PixaLargeImageSize(width: 4096, height: 2048));
  });

  test('parses animated WebP metadata from encoded headers', () {
    final PixaImageMetadata metadata = PixaImageMetadata.parseEncoded(
      _webpVp8xHeader(1024, 768),
    );

    expect(metadata.width, 1024);
    expect(metadata.height, 768);
    expect(metadata.format, PixaImageMetadataFormat.webp);
    expect(metadata.isProgressive, isFalse);
    expect(metadata.isAnimated, isTrue);
  });

  test('parses BMP metadata from encoded headers', () {
    final PixaImageMetadata metadata = PixaImageMetadata.parseEncoded(
      _bmpInfoHeader(800, -600),
    );

    expect(metadata.width, 800);
    expect(metadata.height, 600);
    expect(metadata.format, PixaImageMetadataFormat.bmp);
    expect(metadata.isProgressive, isFalse);
    expect(metadata.isAnimated, isFalse);
  });

  test('parses WBMP metadata from encoded headers', () {
    final PixaImageMetadata metadata = PixaImageMetadata.parseEncoded(
      _wbmpImage(17, 9),
    );

    expect(metadata.width, 17);
    expect(metadata.height, 9);
    expect(metadata.format, PixaImageMetadataFormat.wbmp);
    expect(metadata.isProgressive, isFalse);
    expect(metadata.isAnimated, isFalse);
  });

  test('parses largest ICO entry from encoded directory headers', () {
    final PixaImageMetadata metadata = PixaImageMetadata.parseEncoded(
      _icoHeader(<(int, int)>[(16, 16), (0, 0), (48, 32)]),
    );

    expect(metadata.width, 256);
    expect(metadata.height, 256);
    expect(metadata.format, PixaImageMetadataFormat.ico);
    expect(metadata.isProgressive, isFalse);
    expect(metadata.isAnimated, isFalse);
  });

  test('parses additional runtime-backed format metadata', () {
    final List<(PixaImageMetadataFormat, Uint8List, int, int)> fixtures =
        <(PixaImageMetadataFormat, Uint8List, int, int)>[
          (PixaImageMetadataFormat.tiff, _tiffRgba1x1(), 1, 1),
          (PixaImageMetadataFormat.pnm, _pnmRgb1x1(), 1, 1),
          (PixaImageMetadataFormat.qoi, _qoiRgba1x1(), 1, 1),
          (PixaImageMetadataFormat.tga, _tgaRgb1x1(), 1, 1),
          (PixaImageMetadataFormat.dds, _ddsDxt1_4x4(), 4, 4),
          (PixaImageMetadataFormat.hdr, _hdrRgb1x1(), 1, 1),
          (PixaImageMetadataFormat.farbfeld, _farbfeldRgba1x1(), 1, 1),
          (PixaImageMetadataFormat.pcx, _pcxRgb1x1(), 1, 1),
          (PixaImageMetadataFormat.sgi, _sgiRgb1x1(), 1, 1),
          (PixaImageMetadataFormat.xbm, _xbm1x1(), 1, 1),
          (PixaImageMetadataFormat.xpm, _xpm1x1(), 1, 1),
        ];

    for (final (
          PixaImageMetadataFormat format,
          Uint8List bytes,
          int width,
          int height,
        )
        in fixtures) {
      final PixaImageMetadata metadata = PixaImageMetadata.parseEncoded(bytes);
      expect(metadata.width, width);
      expect(metadata.height, height);
      expect(metadata.format, format);
      expect(metadata.isProgressive, isFalse);
      expect(metadata.isAnimated, isFalse);
    }
  });
}

Uint8List _jpegWithSof(int marker, int width, int height) {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add(<int>[0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00]);
  bytes.add(<int>[0xff, marker, 0x00, 0x11, 0x08]);
  bytes.add(_be16(height));
  bytes.add(_be16(width));
  bytes.add(<int>[0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
  return bytes.toBytes();
}

Uint8List _webpVp8xHeader(int width, int height) {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add('RIFF'.codeUnits);
  bytes.add(_le32(18));
  bytes.add('WEBPVP8X'.codeUnits);
  bytes.add(_le32(10));
  bytes.add(<int>[0x02, 0, 0, 0]);
  bytes.add(_le24(width - 1));
  bytes.add(_le24(height - 1));
  return bytes.toBytes();
}

List<int> _be16(int value) => <int>[(value >> 8) & 0xff, value & 0xff];

List<int> _le16(int value) => <int>[value & 0xff, (value >> 8) & 0xff];

List<int> _le24(int value) => <int>[
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
];

List<int> _le32(int value) {
  final int unsigned = value.toUnsigned(32);
  return <int>[
    unsigned & 0xff,
    (unsigned >> 8) & 0xff,
    (unsigned >> 16) & 0xff,
    (unsigned >> 24) & 0xff,
  ];
}

Uint8List _bmpInfoHeader(int width, int height) {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add('BM'.codeUnits);
  bytes.add(_le32(54));
  bytes.add(<int>[0, 0, 0, 0]);
  bytes.add(_le32(54));
  bytes.add(_le32(40));
  bytes.add(_le32(width));
  bytes.add(_le32(height));
  bytes.add(<int>[1, 0, 24, 0]);
  return bytes.toBytes();
}

Uint8List _wbmpImage(int width, int height) {
  final int rowBytes = (width + 7) ~/ 8;
  final BytesBuilder bytes = BytesBuilder();
  bytes.add(<int>[0, 0]);
  bytes.add(_wbmpMultiByteInteger(width));
  bytes.add(_wbmpMultiByteInteger(height));
  bytes.add(Uint8List(rowBytes * height));
  return bytes.toBytes();
}

Uint8List _icoHeader(List<(int width, int height)> entries) {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add(_le16(0));
  bytes.add(_le16(1));
  bytes.add(_le16(entries.length));
  int dataOffset = 6 + entries.length * 16;
  for (final (int width, int height) in entries) {
    bytes.add(<int>[width, height, 0, 0]);
    bytes.add(_le16(1));
    bytes.add(_le16(32));
    bytes.add(_le32(1));
    bytes.add(_le32(dataOffset));
    dataOffset += 1;
  }
  final Uint8List header = bytes.toBytes();
  return Uint8List(dataOffset)..setRange(0, header.length, header);
}

Uint8List _pnmRgb1x1() {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add('P6\n1 1\n255\n'.codeUnits);
  bytes.add(<int>[255, 0, 0]);
  return bytes.toBytes();
}

Uint8List _tiffRgba1x1() {
  const int entryCount = 10;
  final int ifdEnd = 8 + 2 + entryCount * 12 + 4;
  final int bitsPerSampleOffset = ifdEnd;
  final int pixelOffset = bitsPerSampleOffset + 8;
  final BytesBuilder bytes = BytesBuilder();
  bytes.add('II'.codeUnits);
  bytes.add(_le16(42));
  bytes.add(_le32(8));
  bytes.add(_le16(entryCount));
  bytes.add(_tiffEntry(256, 4, 1, 1));
  bytes.add(_tiffEntry(257, 4, 1, 1));
  bytes.add(_tiffEntry(258, 3, 4, bitsPerSampleOffset));
  bytes.add(_tiffEntry(259, 3, 1, 1));
  bytes.add(_tiffEntry(262, 3, 1, 2));
  bytes.add(_tiffEntry(273, 4, 1, pixelOffset));
  bytes.add(_tiffEntry(277, 3, 1, 4));
  bytes.add(_tiffEntry(278, 4, 1, 1));
  bytes.add(_tiffEntry(279, 4, 1, 4));
  bytes.add(_tiffEntry(338, 3, 1, 2));
  bytes.add(_le32(0));
  bytes.add(<int>[8, 0, 8, 0, 8, 0, 8, 0]);
  bytes.add(<int>[255, 0, 0, 255]);
  return bytes.toBytes();
}

List<int> _tiffEntry(int tag, int type, int count, int value) {
  return <int>[..._le16(tag), ..._le16(type), ..._le32(count), ..._le32(value)];
}

Uint8List _qoiRgba1x1() {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add('qoif'.codeUnits);
  bytes.add(_be32(1));
  bytes.add(_be32(1));
  bytes.add(<int>[4, 0, 0xff, 255, 0, 0, 255]);
  bytes.add(<int>[0, 0, 0, 0, 0, 0, 0, 1]);
  return bytes.toBytes();
}

Uint8List _tgaRgb1x1() {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add(<int>[0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  bytes.add(_le16(1));
  bytes.add(_le16(1));
  bytes.add(<int>[24, 0x20, 0, 0, 255]);
  return bytes.toBytes();
}

Uint8List _ddsDxt1_4x4() {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add('DDS '.codeUnits);
  bytes.add(_le32(124));
  bytes.add(_le32(0x00021007));
  bytes.add(_le32(4));
  bytes.add(_le32(4));
  bytes.add(_le32(8));
  bytes.add(_le32(0));
  bytes.add(_le32(0));
  bytes.add(Uint8List(44));
  bytes.add(_le32(32));
  bytes.add(_le32(4));
  bytes.add('DXT1'.codeUnits);
  bytes.add(Uint8List(20));
  bytes.add(_le32(0x1000));
  bytes.add(Uint8List(16));
  bytes.add(<int>[0x00, 0xf8, 0x00, 0x00, 0, 0, 0, 0]);
  return bytes.toBytes();
}

Uint8List _hdrRgb1x1() {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add('#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 1\n'.codeUnits);
  bytes.add(<int>[255, 0, 0, 128]);
  return bytes.toBytes();
}

Uint8List _farbfeldRgba1x1() {
  final BytesBuilder bytes = BytesBuilder();
  bytes.add('farbfeld'.codeUnits);
  bytes.add(_be32(1));
  bytes.add(_be32(1));
  bytes.add(<int>[0xff, 0xff, 0, 0, 0, 0, 0xff, 0xff]);
  return bytes.toBytes();
}

Uint8List _pcxRgb1x1() {
  final Uint8List bytes = Uint8List(132);
  bytes[0] = 0x0a;
  bytes[1] = 5;
  bytes[2] = 1;
  bytes[3] = 8;
  bytes.setRange(8, 10, _le16(0));
  bytes.setRange(10, 12, _le16(0));
  bytes.setRange(12, 14, _le16(72));
  bytes.setRange(14, 16, _le16(72));
  bytes[65] = 3;
  bytes.setRange(66, 68, _le16(1));
  bytes.setRange(68, 70, _le16(1));
  bytes.setRange(128, 132, <int>[0xc1, 0xff, 0, 0]);
  return bytes;
}

Uint8List _sgiRgb1x1() {
  final Uint8List bytes = Uint8List(515);
  bytes.setRange(0, 2, _be16(0x01da));
  bytes[2] = 0;
  bytes[3] = 1;
  bytes.setRange(4, 6, _be16(3));
  bytes.setRange(6, 8, _be16(1));
  bytes.setRange(8, 10, _be16(1));
  bytes.setRange(10, 12, _be16(3));
  bytes.setRange(16, 20, _be32(255));
  bytes.setRange(512, 515, <int>[255, 0, 0]);
  return bytes;
}

Uint8List _xbm1x1() {
  return Uint8List.fromList(
    '#define test_width 1\n'
            '#define test_height 1\n'
            'static unsigned char test_bits[] = { 0x01 };\n'
        .codeUnits,
  );
}

Uint8List _xpm1x1() {
  return Uint8List.fromList(
    '/* XPM */\n'
            'static char *xpm[] = {\n'
            '"1 1 1 1",\n'
            '"a c #ff0000",\n'
            '"a"\n'
            '};\n'
        .codeUnits,
  );
}

List<int> _be32(int value) {
  final int unsigned = value.toUnsigned(32);
  return <int>[
    (unsigned >> 24) & 0xff,
    (unsigned >> 16) & 0xff,
    (unsigned >> 8) & 0xff,
    unsigned & 0xff,
  ];
}

List<int> _wbmpMultiByteInteger(int value) {
  final List<int> bytes = <int>[value & 0x7f];
  int remaining = value >> 7;
  while (remaining != 0) {
    bytes.insert(0, (remaining & 0x7f) | 0x80);
    remaining >>= 7;
  }
  return bytes;
}
