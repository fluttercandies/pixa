import 'dart:typed_data';

import 'image_metadata.dart';
import 'runtime/capabilities.dart';

/// Signature matcher for one encoded image format.
typedef PixaImageFormatSniffer = bool Function(Uint8List bytes);

/// Built-in encoded image format route used by Dart-side MIME and sniff logic.
final class PixaImageFormatDescriptor {
  /// Creates a built-in image format descriptor.
  const PixaImageFormatDescriptor({
    required this.format,
    required this.runtimeCode,
    required this.primaryMimeType,
    required this.mimeTypes,
    required this.sniff,
  }) : assert(runtimeCode > 0);

  /// Stable image format enum.
  final PixaImageMetadataFormat format;

  /// Stable runtime ABI code for this format.
  final int runtimeCode;

  /// Primary MIME type emitted by Pixa for sniffed bytes.
  final String primaryMimeType;

  /// Stable format route id shared with the runtime ABI.
  String get formatId => format.name;

  /// MIME aliases claimed by this built-in format.
  final Set<String> mimeTypes;

  /// Bounded signature matcher for encoded bytes.
  final PixaImageFormatSniffer sniff;
}

/// Built-in format catalog for Dart routing and tests.
final List<PixaImageFormatDescriptor> pixaBuiltinImageFormatDescriptors =
    List<PixaImageFormatDescriptor>.unmodifiable(
  <PixaImageFormatDescriptor>[
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.jpeg,
      runtimeCode: 1,
      primaryMimeType: 'image/jpeg',
      mimeTypes: const <String>{'image/jpeg', 'image/jpg', 'image/pjpeg'},
      sniff: _isJpeg,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.png,
      runtimeCode: 2,
      primaryMimeType: 'image/png',
      mimeTypes: const <String>{'image/png'},
      sniff: _isPng,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.gif,
      runtimeCode: 3,
      primaryMimeType: 'image/gif',
      mimeTypes: const <String>{'image/gif'},
      sniff: _isGif,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.webp,
      runtimeCode: 4,
      primaryMimeType: 'image/webp',
      mimeTypes: const <String>{'image/webp'},
      sniff: _isWebp,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.bmp,
      runtimeCode: 5,
      primaryMimeType: 'image/bmp',
      mimeTypes: const <String>{
        'image/bmp',
        'image/x-bmp',
        'image/x-ms-bmp',
      },
      sniff: _isBmp,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.wbmp,
      runtimeCode: 6,
      primaryMimeType: 'image/vnd.wap.wbmp',
      mimeTypes: const <String>{'image/vnd.wap.wbmp'},
      sniff: _isWbmp,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.ico,
      runtimeCode: 7,
      primaryMimeType: 'image/x-icon',
      mimeTypes: const <String>{
        'image/x-icon',
        'image/vnd.microsoft.icon',
      },
      sniff: _isIco,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.tiff,
      runtimeCode: 8,
      primaryMimeType: 'image/tiff',
      mimeTypes: const <String>{'image/tiff', 'image/tiff-fx'},
      sniff: _isTiff,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.pnm,
      runtimeCode: 9,
      primaryMimeType: 'image/x-portable-anymap',
      mimeTypes: const <String>{
        'image/x-portable-anymap',
        'image/x-portable-arbitrarymap',
        'image/x-portable-bitmap',
        'image/x-portable-graymap',
        'image/x-portable-pixmap',
      },
      sniff: _isPnm,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.qoi,
      runtimeCode: 10,
      primaryMimeType: 'image/qoi',
      mimeTypes: const <String>{'image/qoi', 'image/x-qoi'},
      sniff: _isQoi,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.tga,
      runtimeCode: 11,
      primaryMimeType: 'image/x-tga',
      mimeTypes: const <String>{
        'image/tga',
        'image/x-tga',
        'application/x-tga',
      },
      sniff: _isTga,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.dds,
      runtimeCode: 12,
      primaryMimeType: 'image/vnd.ms-dds',
      mimeTypes: const <String>{
        'image/vnd.ms-dds',
        'image/vnd-ms.dds',
        'image/x-dds',
      },
      sniff: _isDds,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.hdr,
      runtimeCode: 13,
      primaryMimeType: 'image/vnd.radiance',
      mimeTypes: const <String>{
        'image/vnd.radiance',
        'image/x-hdr',
        'image/hdr',
      },
      sniff: _isHdr,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.farbfeld,
      runtimeCode: 14,
      primaryMimeType: 'image/x-farbfeld',
      mimeTypes: const <String>{'image/x-farbfeld'},
      sniff: _isFarbfeld,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.pcx,
      runtimeCode: 15,
      primaryMimeType: 'image/x-pcx',
      mimeTypes: const <String>{'image/x-pcx', 'image/vnd.zbrush.pcx'},
      sniff: _isPcx,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.sgi,
      runtimeCode: 16,
      primaryMimeType: 'image/sgi',
      mimeTypes: const <String>{'image/sgi', 'image/x-sgi', 'image/x-rgb'},
      sniff: _isSgi,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.xbm,
      runtimeCode: 17,
      primaryMimeType: 'image/x-xbitmap',
      mimeTypes: const <String>{'image/x-xbitmap', 'image/x-xbm'},
      sniff: _isXbm,
    ),
    PixaImageFormatDescriptor(
      format: PixaImageMetadataFormat.xpm,
      runtimeCode: 18,
      primaryMimeType: 'image/x-xpixmap',
      mimeTypes: const <String>{'image/x-xpixmap', 'image/x-xpm'},
      sniff: _isXpm,
    ),
  ],
);

/// Sniffs image MIME type from encoded bytes using signatures that Pixa
/// supports in its Flutter engine or runtime display backends.
String? pixaSniffImageMimeType(Uint8List bytes) {
  final PixaImageMetadataFormat? format = pixaSniffImageFormat(bytes);
  return format == null ? null : pixaPrimaryMimeType(format);
}

/// Sniffs the encoded image format using bounded magic/header bytes.
PixaImageMetadataFormat? pixaSniffImageFormat(Uint8List bytes) {
  for (final PixaImageFormatDescriptor descriptor
      in pixaBuiltinImageFormatDescriptors) {
    if (descriptor.sniff(bytes)) {
      return descriptor.format;
    }
  }
  return null;
}

/// Returns whether [mimeType] requires the runtime display backend.
bool pixaIsRuntimeOnlyDisplayMime(Object? mimeType) {
  final PixaImageMetadataFormat? format = pixaImageFormatFromMimeType(mimeType);
  return format != null && pixaUsesDefaultRuntimeDisplay(format);
}

/// Returns the Pixa format for a MIME type, including common aliases.
PixaImageMetadataFormat? pixaImageFormatFromMimeType(Object? mimeType) {
  if (mimeType is! String) {
    return null;
  }
  final String normalized = mimeType.split(';').first.trim().toLowerCase();
  if (normalized.isEmpty) {
    return null;
  }
  return _descriptorByMimeType[normalized]?.format;
}

/// Returns the Pixa format for a stable format id.
PixaImageMetadataFormat? pixaImageFormatFromFormatId(Object? formatId) {
  if (formatId is! String) {
    return null;
  }
  final String normalized = formatId.trim().toLowerCase();
  if (normalized.isEmpty) {
    return null;
  }
  return _descriptorByFormatId[normalized]?.format;
}

/// Primary MIME type for a built-in encoded image format.
String pixaPrimaryMimeType(PixaImageMetadataFormat format) {
  final PixaImageFormatDescriptor? descriptor = _descriptorByFormat[format];
  if (descriptor == null) {
    throw StateError('Missing Pixa image format descriptor for $format.');
  }
  return descriptor.primaryMimeType;
}

/// Stable format route id for a built-in encoded image format.
String pixaFormatId(PixaImageMetadataFormat format) {
  final PixaImageFormatDescriptor? descriptor = _descriptorByFormat[format];
  if (descriptor == null) {
    throw StateError('Missing Pixa image format descriptor for $format.');
  }
  return descriptor.formatId;
}

/// Built-in descriptor for [format], if Pixa has one.
PixaImageFormatDescriptor? pixaImageFormatDescriptorForFormat(
  PixaImageMetadataFormat format,
) {
  return _descriptorByFormat[format];
}

/// Built-in descriptor for [mimeType], if Pixa has one.
PixaImageFormatDescriptor? pixaImageFormatDescriptorForMimeType(
  Object? mimeType,
) {
  final PixaImageMetadataFormat? format = pixaImageFormatFromMimeType(mimeType);
  return format == null ? null : _descriptorByFormat[format];
}

/// Built-in descriptor for [formatId], if Pixa has one.
PixaImageFormatDescriptor? pixaImageFormatDescriptorForFormatId(
  Object? formatId,
) {
  final PixaImageMetadataFormat? format = pixaImageFormatFromFormatId(formatId);
  return format == null ? null : _descriptorByFormat[format];
}

/// Returns whether runtime capabilities select runtime display by default.
bool pixaUsesDefaultRuntimeDisplay(PixaImageMetadataFormat format) {
  final Set<PixaImageMetadataFormat>? cached = _defaultRuntimeDisplayFormats;
  if (cached != null) {
    return cached.contains(format);
  }
  final Set<PixaImageMetadataFormat>? formats =
      _readDefaultRuntimeDisplayFormats();
  if (formats == null) {
    return false;
  }
  _defaultRuntimeDisplayFormats = formats;
  return formats.contains(format);
}

Set<PixaImageMetadataFormat>? _defaultRuntimeDisplayFormats;

final Map<PixaImageMetadataFormat, PixaImageFormatDescriptor>
    _descriptorByFormat = <PixaImageMetadataFormat, PixaImageFormatDescriptor>{
  for (final PixaImageFormatDescriptor descriptor
      in pixaBuiltinImageFormatDescriptors)
    descriptor.format: descriptor,
};

final Map<String, PixaImageFormatDescriptor> _descriptorByMimeType =
    _buildMimeTypeDescriptorMap();

final Map<String, PixaImageFormatDescriptor> _descriptorByFormatId =
    <String, PixaImageFormatDescriptor>{
  for (final PixaImageFormatDescriptor descriptor
      in pixaBuiltinImageFormatDescriptors)
    descriptor.formatId: descriptor,
};

Map<String, PixaImageFormatDescriptor> _buildMimeTypeDescriptorMap() {
  final Map<String, PixaImageFormatDescriptor> descriptors =
      <String, PixaImageFormatDescriptor>{};
  for (final PixaImageFormatDescriptor descriptor
      in pixaBuiltinImageFormatDescriptors) {
    for (final String mimeType in descriptor.mimeTypes) {
      descriptors[mimeType.toLowerCase()] = descriptor;
    }
  }
  return Map<String, PixaImageFormatDescriptor>.unmodifiable(descriptors);
}

Set<PixaImageMetadataFormat>? _readDefaultRuntimeDisplayFormats() {
  try {
    final Set<PixaImageMetadataFormat> formats = PixaRuntimeCapabilities
            .current()
        .imageFormats
        .where((PixaRuntimeImageFormatCapability capability) =>
            capability.defaultRuntimeDisplay)
        .map((PixaRuntimeImageFormatCapability capability) => capability.format)
        .toSet();
    return formats.isEmpty ? null : formats;
  } on Object {
    return null;
  }
}

bool _isJpeg(Uint8List bytes) {
  return _startsWith(bytes, const <int>[0xff, 0xd8, 0xff]);
}

bool _isPng(Uint8List bytes) {
  return _startsWith(
      bytes, const <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
}

bool _isGif(Uint8List bytes) {
  return _startsWithAscii(bytes, 'GIF87a') || _startsWithAscii(bytes, 'GIF89a');
}

bool _isWebp(Uint8List bytes) {
  return bytes.length >= 12 &&
      _asciiAt(bytes, 0, 'RIFF') &&
      _asciiAt(bytes, 8, 'WEBP');
}

bool _isBmp(Uint8List bytes) {
  return _startsWithAscii(bytes, 'BM');
}

bool _isDds(Uint8List bytes) {
  return _startsWithAscii(bytes, 'DDS ');
}

bool _isHdr(Uint8List bytes) {
  return _startsWithAscii(bytes, '#?RADIANCE');
}

bool _isQoi(Uint8List bytes) {
  return _startsWithAscii(bytes, 'qoif');
}

bool _isFarbfeld(Uint8List bytes) {
  return _startsWithAscii(bytes, 'farbfeld');
}

bool _isIco(Uint8List bytes) {
  return bytes.length >= 6 &&
      bytes[0] == 0x00 &&
      bytes[1] == 0x00 &&
      bytes[2] == 0x01 &&
      bytes[3] == 0x00 &&
      (bytes[4] != 0x00 || bytes[5] != 0x00);
}

bool _isTiff(Uint8List bytes) {
  return _startsWith(bytes, const <int>[0x4d, 0x4d, 0x00, 0x2a]) ||
      _startsWith(bytes, const <int>[0x49, 0x49, 0x2a, 0x00]);
}

bool _isWbmp(Uint8List bytes) {
  if (bytes.length < 5 || bytes[0] != 0x00 || bytes[1] != 0x00) {
    return false;
  }
  final (int width, int widthEnd)? width = _readWbmpInteger(bytes, 2);
  if (width == null || width.$1 == 0 || width.$2 >= bytes.length) {
    return false;
  }
  final (int height, int dataOffset)? height =
      _readWbmpInteger(bytes, width.$2);
  if (height == null || height.$1 == 0 || height.$2 > bytes.length) {
    return false;
  }
  final int rowBytes = (width.$1 + 7) ~/ 8;
  final int expectedLength = height.$2 + rowBytes * height.$1;
  return expectedLength == bytes.length;
}

bool _isPnm(Uint8List bytes) {
  return bytes.length >= 3 &&
      bytes[0] == 0x50 &&
      bytes[1] >= 0x31 &&
      bytes[1] <= 0x37 &&
      _isAsciiWhitespace(bytes[2]);
}

bool _isTga(Uint8List bytes) {
  if (bytes.length < 18) {
    return false;
  }
  final int colorMapType = bytes[1];
  final int imageType = bytes[2];
  final int width = bytes[12] | (bytes[13] << 8);
  final int height = bytes[14] | (bytes[15] << 8);
  final int pixelDepth = bytes[16];
  final bool validImageType = imageType == 1 ||
      imageType == 2 ||
      imageType == 3 ||
      imageType == 9 ||
      imageType == 10 ||
      imageType == 11;
  final bool validDepth = pixelDepth == 8 ||
      pixelDepth == 15 ||
      pixelDepth == 16 ||
      pixelDepth == 24 ||
      pixelDepth == 32;
  return colorMapType <= 1 &&
      validImageType &&
      width > 0 &&
      height > 0 &&
      validDepth;
}

bool _isPcx(Uint8List bytes) {
  return bytes.length >= 4 &&
      bytes[0] == 0x0a &&
      (bytes[1] == 0 ||
          bytes[1] == 2 ||
          bytes[1] == 3 ||
          bytes[1] == 4 ||
          bytes[1] == 5) &&
      bytes[2] == 1 &&
      (bytes[3] == 1 || bytes[3] == 2 || bytes[3] == 4 || bytes[3] == 8);
}

bool _isSgi(Uint8List bytes) {
  return bytes.length >= 4 &&
      bytes[0] == 0x01 &&
      bytes[1] == 0xda &&
      (bytes[2] == 0 || bytes[2] == 1) &&
      (bytes[3] == 1 || bytes[3] == 2);
}

bool _isXbm(Uint8List bytes) {
  return _startsWithAscii(bytes, '#define ') &&
      _containsAscii(bytes, '_bits[]');
}

bool _isXpm(Uint8List bytes) {
  return _startsWithAscii(bytes, '/* XPM */');
}

(int, int)? _readWbmpInteger(Uint8List bytes, int offset) {
  int index = offset;
  int value = 0;
  int read = 0;
  while (index < bytes.length) {
    final int byte = bytes[index];
    index += 1;
    read += 1;
    if (read > 5) {
      return null;
    }
    value = (value << 7) + (byte & 0x7f);
    if (value > 0xffffffff) {
      return null;
    }
    if (byte & 0x80 == 0) {
      return (value, index);
    }
  }
  return null;
}

bool _containsAscii(Uint8List bytes, String value) {
  for (int offset = 0; offset + value.length <= bytes.length; offset += 1) {
    if (_asciiAt(bytes, offset, value)) {
      return true;
    }
  }
  return false;
}

bool _startsWithAscii(Uint8List bytes, String value) {
  return _asciiAt(bytes, 0, value);
}

bool _asciiAt(Uint8List bytes, int offset, String value) {
  if (bytes.length < offset + value.length) {
    return false;
  }
  for (int index = 0; index < value.length; index += 1) {
    if (bytes[offset + index] != value.codeUnitAt(index)) {
      return false;
    }
  }
  return true;
}

bool _startsWith(Uint8List bytes, List<int> signature) {
  if (bytes.length < signature.length) {
    return false;
  }
  for (int index = 0; index < signature.length; index += 1) {
    if (bytes[index] != signature[index]) {
      return false;
    }
  }
  return true;
}

bool _isAsciiWhitespace(int value) {
  return value == 0x09 || value == 0x0a || value == 0x0d || value == 0x20;
}
