import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart'
    show PixaRuntimeCapabilities, PixaRuntimeImageFormatCapability;
import 'package:pixa/src/image_format.dart';
import 'package:pixa/src/image_format_catalog.dart';
import 'package:pixa/src/runtime/runtime_binary.dart';
import 'package:pixa/src/runtime/runtime_loader.dart';

void main() {
  test('runtime image format capabilities expose display matrix', () {
    final PixaRuntimeCapabilities capabilities =
        PixaRuntimeCapabilities.current();

    final PixaRuntimeImageFormatCapability jpeg = capabilities.imageFormats
        .singleWhere(
          (PixaRuntimeImageFormatCapability capability) =>
              capability.format == PixaImageMetadataFormat.jpeg,
        );
    final PixaRuntimeImageFormatCapability png = capabilities.imageFormats
        .singleWhere(
          (PixaRuntimeImageFormatCapability capability) =>
              capability.format == PixaImageMetadataFormat.png,
        );
    final PixaRuntimeImageFormatCapability ico = capabilities.imageFormats
        .singleWhere(
          (PixaRuntimeImageFormatCapability capability) =>
              capability.format == PixaImageMetadataFormat.ico,
        );
    final PixaRuntimeImageFormatCapability pcx = capabilities.imageFormats
        .singleWhere(
          (PixaRuntimeImageFormatCapability capability) =>
              capability.format == PixaImageMetadataFormat.pcx,
        );
    final PixaRuntimeImageFormatCapability wbmp = capabilities.imageFormats
        .singleWhere(
          (PixaRuntimeImageFormatCapability capability) =>
              capability.format == PixaImageMetadataFormat.wbmp,
        );
    final PixaRuntimeImageFormatCapability bmp = capabilities.imageFormats
        .singleWhere(
          (PixaRuntimeImageFormatCapability capability) =>
              capability.format == PixaImageMetadataFormat.bmp,
        );
    final PixaRuntimeImageFormatCapability farbfeld = capabilities.imageFormats
        .singleWhere(
          (PixaRuntimeImageFormatCapability capability) =>
              capability.format == PixaImageMetadataFormat.farbfeld,
        );

    expect(
      capabilities.imageFormats
          .map(
            (PixaRuntimeImageFormatCapability capability) => capability.format,
          )
          .toSet(),
      PixaImageMetadataFormat.values.toSet(),
    );
    expect(jpeg.sniffing, isTrue);
    expect(jpeg.metadata, isTrue);
    expect(jpeg.engineDisplay, isTrue);
    expect(jpeg.runtimeDisplay, isTrue);
    expect(jpeg.regionDecode, isFalse);
    expect(jpeg.defaultRuntimeDisplay, isFalse);
    expect(png.regionDecode, isTrue);
    expect(bmp.regionDecode, isTrue);
    expect(farbfeld.regionDecode, isTrue);
    expect(wbmp.engineDisplay, isTrue);
    expect(wbmp.runtimeDisplay, isTrue);
    expect(wbmp.regionDecode, isFalse);
    expect(wbmp.defaultRuntimeDisplay, isFalse);
    expect(ico.engineDisplay, isFalse);
    expect(ico.runtimeDisplay, isTrue);
    expect(ico.defaultRuntimeDisplay, isTrue);
    expect(pcx.engineDisplay, isFalse);
    expect(pcx.metadata, isTrue);
    expect(pcx.runtimeDisplay, isTrue);
    expect(pcx.processorDecode, isTrue);
    expect(pcx.defaultRuntimeDisplay, isTrue);
  });

  test('Dart display MIME policy follows runtime capability matrix', () {
    final PixaRuntimeCapabilities capabilities =
        PixaRuntimeCapabilities.current();
    final Map<PixaImageMetadataFormat, bool> defaults =
        <PixaImageMetadataFormat, bool>{
          for (final PixaRuntimeImageFormatCapability capability
              in capabilities.imageFormats)
            capability.format: capability.defaultRuntimeDisplay,
        };

    for (final MapEntry<PixaImageMetadataFormat, String> entry
        in _primaryMimeTypes.entries) {
      expect(
        pixaIsRuntimeOnlyDisplayMime(entry.value),
        defaults[entry.key],
        reason: '${entry.key.name} should follow runtime PXF1 flags',
      );
      final PixaImageFormatRoute route = const PixaImageFormatCatalog()
          .routeForMimeType(entry.value)!;
      expect(
        route.capabilities.defaultRuntimeDisplay,
        defaults[entry.key],
        reason: '${entry.key.name} route should follow runtime PXF1 flags',
      );
    }
    expect(
      pixaImageFormatFromMimeType('image/x-pcx; charset=binary'),
      PixaImageMetadataFormat.pcx,
    );
    expect(pixaIsRuntimeOnlyDisplayMime('image/png; charset=binary'), isFalse);
  });

  test('Dart display MIME policy marks stable runtime-only raster formats', () {
    for (final PixaImageMetadataFormat format
        in _stableRuntimeOnlyRasterFormats) {
      expect(
        pixaUsesDefaultRuntimeDisplay(format),
        isTrue,
        reason: '${format.name} should default to runtime-rgba display',
      );
      expect(
        pixaIsRuntimeOnlyDisplayMime(_primaryMimeTypes[format]),
        isTrue,
        reason: '${format.name} primary MIME should select runtime-rgba',
      );
    }
  });

  test('Dart built-in image format descriptors are the routing source', () {
    final List<PixaImageFormatDescriptor> descriptors =
        pixaBuiltinImageFormatDescriptors;

    expect(
      descriptors
          .map((PixaImageFormatDescriptor descriptor) => descriptor.format)
          .toSet(),
      PixaImageMetadataFormat.values.toSet(),
    );
    expect(
      descriptors
          .map((PixaImageFormatDescriptor descriptor) => descriptor.format)
          .length,
      descriptors
          .map((PixaImageFormatDescriptor descriptor) => descriptor.format)
          .toSet()
          .length,
    );
    expect(
      descriptors
          .map((PixaImageFormatDescriptor descriptor) => descriptor.runtimeCode)
          .toList(growable: false),
      List<int>.generate(descriptors.length, (int index) => index + 1),
    );

    final Set<String> claimedMimeTypes = <String>{};
    for (final PixaImageFormatDescriptor descriptor in descriptors) {
      expect(
        pixaPrimaryMimeType(descriptor.format),
        descriptor.primaryMimeType,
      );
      expect(
        pixaImageFormatFromMimeType(descriptor.primaryMimeType),
        descriptor.format,
      );
      expect(pixaFormatId(descriptor.format), descriptor.format.name);
      expect(
        pixaImageFormatFromFormatId(descriptor.format.name),
        descriptor.format,
      );
      for (final String mimeType in descriptor.mimeTypes) {
        expect(
          claimedMimeTypes.add(mimeType),
          isTrue,
          reason: '$mimeType is claimed by more than one descriptor',
        );
        expect(pixaImageFormatFromMimeType(mimeType), descriptor.format);
      }
    }
  });

  test('runtime plugin source is encoded in the compact request ABI', () {
    final PixaRequest request = PixaRequest(
      source: PixaSource.runtimePlugin(
        sourceKind: 's3',
        locator: 's3://bucket/key.gif',
      ),
    );

    final Uint8List payload = PixaRuntimeLoader.encodeRequest(request);
    final PixaRuntimeBinaryReader reader = PixaRuntimeBinaryReader(payload);

    expect(reader.readMagic(0x50, 0x58, 0x52, 0x31), isTrue);
    expect(reader.readUint8(), 5);
    expect(reader.readString(), 's3');
    expect(reader.readString(), 's3://bucket/key.gif');
  });

  test('target size and decoded pixel budget are encoded in request ABI', () {
    final PixaRequest request = PixaRequest(
      source: PixaSource.bytes(Uint8List(1), id: 'targeted'),
      targetSize: const PixaTargetSize(width: 320, height: 180),
      limits: const PixaRequestLimits(maxDecodedPixels: 57600),
    );

    final Uint8List payload = PixaRuntimeLoader.encodeRequest(request);
    final PixaRuntimeBinaryReader reader = PixaRuntimeBinaryReader(payload);

    expect(reader.readMagic(0x50, 0x58, 0x52, 0x31), isTrue);
    expect(reader.readUint8(), 2);
    expect(reader.readString(), 'targeted');
    final int headerCount = reader.readUint32();
    for (int index = 0; index < headerCount; index++) {
      reader.readString();
      reader.readString();
    }
    reader.readString();
    reader.readString();
    reader.readString();
    expect(reader.readUint32(), 320);
    expect(reader.readUint32(), 180);
    reader.readUint8();
    reader.readUint8();
    reader.readUint8();
    reader.readUint8();
    reader.readInt64();
    reader.readUint64();
    expect(reader.readUint64(), 57600);
  });

  test('decoder route hints are encoded in compact request ABI', () {
    final PixaRequest request = PixaRequest(
      source: PixaSource.bytes(Uint8List(1), id: 'third-party-format'),
      decoderOptions: const <String, Object?>{
        'mimeType': 'Image/Third-Party; charset=binary',
        'formatId': 'THIRD-PARTY',
      },
    );

    final Uint8List payload = PixaRuntimeLoader.encodeRequest(request);
    final PixaRuntimeBinaryReader reader = PixaRuntimeBinaryReader(payload);

    expect(reader.readMagic(0x50, 0x58, 0x52, 0x31), isTrue);
    expect(reader.readUint8(), 2);
    expect(reader.readString(), 'third-party-format');
    final int headerCount = reader.readUint32();
    for (int index = 0; index < headerCount; index++) {
      reader.readString();
      reader.readString();
    }
    reader.readString();
    reader.readString();
    reader.readString();
    reader.readUint32();
    reader.readUint32();
    reader.readUint8();
    reader.readUint8();
    reader.readUint8();
    reader.readUint8();
    reader.readInt64();
    for (int index = 0; index < 9; index++) {
      reader.readUint64();
    }
    reader.readUint8();
    reader.readUint8();
    reader.readUint8();
    reader.readUint64();
    reader.readUint64();
    reader.readUint64();
    expect(reader.readString(), 'image/third-party');
    expect(reader.readString(), 'third-party');
  });

  test('runtime plugin locator secrets partition keys without leaking', () {
    final PixaRequest first = PixaRequest(
      source: PixaSource.runtimePlugin(
        sourceKind: 's3',
        locator: 's3://bucket/key.gif?X-Amz-Signature=alpha&version=preview',
      ),
    );
    final PixaRequest second = PixaRequest(
      source: PixaSource.runtimePlugin(
        sourceKind: 'S3',
        locator: 's3://bucket/key.gif?X-Amz-Signature=bravo&version=preview',
      ),
    );

    expect(first.encodedCacheKey, isNot(second.encodedCacheKey));
    expect(first.cacheKey.debugLabel, isNot(contains('alpha')));
    expect(second.cacheKey.debugLabel, isNot(contains('bravo')));
    expect(first.source.cacheMaterial.toString(), isNot(contains('alpha')));
    expect(second.source.cacheMaterial.toString(), isNot(contains('bravo')));
  });

  test('owned buffer decodes to RGBA owned buffer', () {
    final Uint8List bytes = _minimalGif();
    final PixaRuntimeLoadResult load = const PixaRuntimeLoader(rootPath: '')
        .load(
          PixaRequest(
            source: PixaSource.bytes(bytes, id: 'runtime-rgba'),
            cachePolicy: PixaCachePolicy.noStore(),
          ),
          inlineBytes: bytes,
        );
    addTearDown(load.dispose);

    final PixaRuntimeRgbaImage rgba = load.buffer.decodeRgba(
      maxDecodedPixels: 1,
      maxOutputBytes: 4,
    );
    addTearDown(rgba.dispose);

    expect(rgba.width, 1);
    expect(rgba.height, 1);
    expect(rgba.rowBytes, 4);
    expect(rgba.bytes.length, 4);
  });

  test('runtime RGBA decode reports typed output budget failure', () {
    final Uint8List bytes = _minimalGif();
    final PixaRuntimeLoadResult load = const PixaRuntimeLoader(rootPath: '')
        .load(
          PixaRequest(
            source: PixaSource.bytes(bytes, id: 'runtime-rgba-budget'),
            cachePolicy: PixaCachePolicy.noStore(),
          ),
          inlineBytes: bytes,
        );
    addTearDown(load.dispose);

    expect(
      () => load.buffer.decodeRgba(maxDecodedPixels: 1, maxOutputBytes: 3),
      throwsA(
        isA<PixaFailure>()
            .having(
              (PixaFailure failure) => failure.stage,
              'stage',
              PixaStage.decode,
            )
            .having(
              (PixaFailure failure) => failure.safeMessage,
              'message',
              contains('RGBA output bytes exceed limit'),
            ),
      ),
    );
  });
}

const Map<PixaImageMetadataFormat, String> _primaryMimeTypes =
    <PixaImageMetadataFormat, String>{
      PixaImageMetadataFormat.jpeg: 'image/jpeg',
      PixaImageMetadataFormat.png: 'image/png',
      PixaImageMetadataFormat.gif: 'image/gif',
      PixaImageMetadataFormat.webp: 'image/webp',
      PixaImageMetadataFormat.bmp: 'image/bmp',
      PixaImageMetadataFormat.wbmp: 'image/vnd.wap.wbmp',
      PixaImageMetadataFormat.ico: 'image/x-icon',
      PixaImageMetadataFormat.tiff: 'image/tiff',
      PixaImageMetadataFormat.pnm: 'image/x-portable-anymap',
      PixaImageMetadataFormat.qoi: 'image/qoi',
      PixaImageMetadataFormat.tga: 'image/x-tga',
      PixaImageMetadataFormat.dds: 'image/vnd.ms-dds',
      PixaImageMetadataFormat.hdr: 'image/vnd.radiance',
      PixaImageMetadataFormat.farbfeld: 'image/x-farbfeld',
      PixaImageMetadataFormat.pcx: 'image/x-pcx',
      PixaImageMetadataFormat.sgi: 'image/sgi',
      PixaImageMetadataFormat.xbm: 'image/x-xbitmap',
      PixaImageMetadataFormat.xpm: 'image/x-xpixmap',
    };

const Set<PixaImageMetadataFormat> _stableRuntimeOnlyRasterFormats =
    <PixaImageMetadataFormat>{
      PixaImageMetadataFormat.ico,
      PixaImageMetadataFormat.tiff,
      PixaImageMetadataFormat.pnm,
      PixaImageMetadataFormat.qoi,
      PixaImageMetadataFormat.tga,
      PixaImageMetadataFormat.dds,
      PixaImageMetadataFormat.hdr,
      PixaImageMetadataFormat.farbfeld,
      PixaImageMetadataFormat.pcx,
      PixaImageMetadataFormat.sgi,
      PixaImageMetadataFormat.xbm,
      PixaImageMetadataFormat.xpm,
    };

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
