import 'dart:typed_data';

import 'image_format.dart';
import 'image_metadata.dart';
import 'registry.dart';
import 'runtime/capabilities.dart';

/// Route source for a resolved encoded image format.
enum PixaImageFormatRouteSource {
  /// A Pixa built-in raster format.
  builtIn,

  /// A registered plugin decoder route.
  plugin,
}

/// Resolved encoded image route and display capability hints.
final class PixaImageFormatRoute {
  const PixaImageFormatRoute._({
    required this.source,
    required this.capabilities,
    this.builtInDescriptor,
    this.pluginDecoder,
    String? mimeType,
    String? formatId,
  }) : _mimeType = mimeType,
       _formatId = formatId;

  /// Creates a route for a built-in image format descriptor.
  factory PixaImageFormatRoute.builtIn(PixaImageFormatDescriptor descriptor) {
    return PixaImageFormatRoute._(
      source: PixaImageFormatRouteSource.builtIn,
      capabilities: PixaImageFormatRouteCapabilities.runtime(
        _runtimeCapabilityFor(descriptor.format),
      ),
      builtInDescriptor: descriptor,
    );
  }

  /// Creates a route for a plugin decoder descriptor.
  factory PixaImageFormatRoute.plugin(
    PixaDecoderDescriptor decoder, {
    PixaDecoderSignature? signature,
    String? mimeType,
    String? formatId,
  }) {
    return PixaImageFormatRoute._(
      source: PixaImageFormatRouteSource.plugin,
      capabilities: PixaImageFormatRouteCapabilities.plugin(decoder),
      pluginDecoder: decoder,
      mimeType:
          _normalizeMimeType(mimeType) ??
          _firstNormalized(decoder.mimeTypes, _normalizeMimeType) ??
          _normalizeMimeType(signature?.mimeType),
      formatId:
          _normalizeFormatId(formatId) ??
          _firstNormalized(decoder.formatIds, _normalizeFormatId) ??
          _normalizeFormatId(signature?.formatId),
    );
  }

  /// Route source.
  final PixaImageFormatRouteSource source;

  /// Built-in format descriptor, when [source] is built-in.
  final PixaImageFormatDescriptor? builtInDescriptor;

  /// Plugin decoder descriptor, when [source] is plugin.
  final PixaDecoderDescriptor? pluginDecoder;

  /// Unified capability contract for this route.
  final PixaImageFormatRouteCapabilities capabilities;

  final String? _mimeType;
  final String? _formatId;

  /// Primary MIME type for this route.
  String? get mimeType => builtInDescriptor?.primaryMimeType ?? _mimeType;

  /// Stable format id for this route.
  String? get formatId => builtInDescriptor?.formatId ?? _formatId;

  /// Whether this route can decode bounded image regions.
  bool get regionDecode => capabilities.regionDecode;

  /// Whether ordinary display should select the runtime backend.
  bool get defaultRuntimeDisplay => capabilities.defaultRuntimeDisplay;
}

/// Unified decoder/display capabilities for one resolved format route.
final class PixaImageFormatRouteCapabilities {
  const PixaImageFormatRouteCapabilities._({
    required this.metadataProbe,
    required this.staticDecode,
    required this.animatedDecode,
    required this.progressiveDecode,
    required this.regionDecode,
    required this.processorInput,
    required this.streamingInput,
    required this.engineDisplay,
    required this.runtimeDisplay,
    required this.defaultRuntimeDisplay,
    required this.zeroCopyInput,
    required this.ownedOutputBuffers,
    required this.stable,
  });

  /// Creates capabilities from the runtime PXF1 format matrix.
  factory PixaImageFormatRouteCapabilities.runtime(
    PixaRuntimeImageFormatCapability? capability,
  ) {
    if (capability == null) {
      return const PixaImageFormatRouteCapabilities._(
        metadataProbe: false,
        staticDecode: false,
        animatedDecode: false,
        progressiveDecode: false,
        regionDecode: false,
        processorInput: false,
        streamingInput: false,
        engineDisplay: false,
        runtimeDisplay: false,
        defaultRuntimeDisplay: false,
        zeroCopyInput: false,
        ownedOutputBuffers: false,
        stable: false,
      );
    }
    return PixaImageFormatRouteCapabilities._(
      metadataProbe: capability.metadata,
      staticDecode: capability.engineDisplay || capability.runtimeDisplay,
      animatedDecode: capability.animated,
      progressiveDecode: false,
      regionDecode: capability.regionDecode,
      processorInput: capability.processorDecode,
      streamingInput: capability.runtimeDisplay || capability.processorDecode,
      engineDisplay: capability.engineDisplay,
      runtimeDisplay: capability.runtimeDisplay,
      defaultRuntimeDisplay: capability.defaultRuntimeDisplay,
      zeroCopyInput: capability.runtimeDisplay || capability.processorDecode,
      ownedOutputBuffers:
          capability.runtimeDisplay || capability.processorDecode,
      stable:
          capability.metadata &&
          (capability.engineDisplay ||
              capability.runtimeDisplay ||
              capability.processorDecode),
    );
  }

  /// Creates capabilities from a plugin decoder descriptor.
  factory PixaImageFormatRouteCapabilities.plugin(
    PixaDecoderDescriptor decoder,
  ) {
    final PixaDecoderCapabilities capabilities = decoder.capabilities;
    return PixaImageFormatRouteCapabilities._(
      metadataProbe: capabilities.metadataProbe,
      staticDecode: capabilities.staticDecode,
      animatedDecode: capabilities.animatedDecode,
      progressiveDecode: capabilities.progressiveDecode,
      regionDecode: capabilities.regionDecode,
      processorInput: capabilities.processorInput,
      streamingInput: capabilities.streamingInput,
      engineDisplay: false,
      runtimeDisplay:
          decoder.executionKind == PixaPluginExecutionKind.runtime &&
          capabilities.staticDecode,
      defaultRuntimeDisplay: capabilities.defaultRuntimeDisplay,
      zeroCopyInput: capabilities.zeroCopyInput,
      ownedOutputBuffers: capabilities.ownedOutputBuffers,
      stable: capabilities.stable,
    );
  }

  /// Can read dimensions/traits from bounded headers.
  final bool metadataProbe;

  /// Can decode a static image frame.
  final bool staticDecode;

  /// Can decode animated image streams.
  final bool animatedDecode;

  /// Can emit progressive/intermediate frames while streaming.
  final bool progressiveDecode;

  /// Can decode a requested region without full-frame pixel decode.
  final bool regionDecode;

  /// Can provide decoded pixels to runtime processors.
  final bool processorInput;

  /// Can consume large input through stream handles or borrowed runtime bytes.
  final bool streamingInput;

  /// Flutter engine display backend can display this route.
  final bool engineDisplay;

  /// Runtime display backend can display this route.
  final bool runtimeDisplay;

  /// Ordinary display should select runtime display by default.
  final bool defaultRuntimeDisplay;

  /// Input can avoid Dart/Rust hot-path byte copies.
  final bool zeroCopyInput;

  /// Large outputs use owned buffers with explicit lifetime.
  final bool ownedOutputBuffers;

  /// Route has production fixtures and compatibility coverage.
  final bool stable;
}

/// Combined route catalog for built-in formats and optional plugin decoders.
final class PixaImageFormatCatalog {
  /// Creates a catalog view.
  const PixaImageFormatCatalog({this.registry});

  /// Optional plugin registry queried after built-in routes.
  final PixaRegistry? registry;

  /// Resolves a route from a MIME type.
  PixaImageFormatRoute? routeForMimeType(Object? mimeType) {
    final PixaImageFormatDescriptor? builtIn =
        pixaImageFormatDescriptorForMimeType(mimeType);
    if (builtIn != null) {
      return PixaImageFormatRoute.builtIn(builtIn);
    }
    final String? normalized = _normalizeMimeType(mimeType);
    final PixaDecoderDescriptor? decoder = normalized == null
        ? null
        : registry?.decoderForMimeType(normalized);
    return decoder == null
        ? null
        : PixaImageFormatRoute.plugin(decoder, mimeType: normalized);
  }

  /// Resolves a route from a stable format id.
  PixaImageFormatRoute? routeForFormatId(Object? formatId) {
    final PixaImageFormatDescriptor? builtIn =
        pixaImageFormatDescriptorForFormatId(formatId);
    if (builtIn != null) {
      return PixaImageFormatRoute.builtIn(builtIn);
    }
    final String? normalized = _normalizeFormatId(formatId);
    final PixaDecoderDescriptor? decoder = normalized == null
        ? null
        : registry?.decoderForFormatId(normalized);
    return decoder == null
        ? null
        : PixaImageFormatRoute.plugin(decoder, formatId: normalized);
  }

  /// Resolves a route from explicit hints or bounded encoded bytes.
  PixaImageFormatRoute? routeForPayload(
    Uint8List bytes, {
    Object? formatId,
    Object? mimeType,
  }) {
    return routeForFormatId(formatId) ??
        routeForMimeType(mimeType) ??
        _builtInRouteForBytes(bytes) ??
        _pluginRouteForSignature(bytes);
  }

  PixaImageFormatRoute? _builtInRouteForBytes(Uint8List bytes) {
    final PixaImageMetadataFormat? format = pixaSniffImageFormat(bytes);
    final PixaImageFormatDescriptor? descriptor = format == null
        ? null
        : pixaImageFormatDescriptorForFormat(format);
    return descriptor == null ? null : PixaImageFormatRoute.builtIn(descriptor);
  }

  PixaImageFormatRoute? _pluginRouteForSignature(Uint8List bytes) {
    final PixaRegistry? activeRegistry = registry;
    if (activeRegistry == null) {
      return null;
    }
    PixaDecoderDescriptor? selected;
    PixaDecoderSignature? selectedSignature;
    for (final PixaDecoderDescriptor decoder in activeRegistry.decoders) {
      for (final PixaDecoderSignature signature in decoder.signatures) {
        if (!signature.matches(bytes)) {
          continue;
        }
        if (selected == null || decoder.priority > selected.priority) {
          selected = decoder;
          selectedSignature = signature;
        }
      }
    }
    return selected == null
        ? null
        : PixaImageFormatRoute.plugin(selected, signature: selectedSignature);
  }
}

PixaRuntimeImageFormatCapability? _runtimeCapabilityFor(
  PixaImageMetadataFormat format,
) {
  try {
    for (final PixaRuntimeImageFormatCapability capability
        in PixaRuntimeCapabilities.current().imageFormats) {
      if (capability.format == format) {
        return capability;
      }
    }
  } on Object {
    return null;
  }
  return null;
}

String? _firstNormalized(
  Iterable<String> values,
  String? Function(Object? value) normalize,
) {
  for (final String value in values) {
    final String? normalized = normalize(value);
    if (normalized != null) {
      return normalized;
    }
  }
  return null;
}

String? _normalizeMimeType(Object? mimeType) {
  if (mimeType is! String) {
    return null;
  }
  final String normalized = mimeType.split(';').first.trim().toLowerCase();
  return normalized.isEmpty ? null : normalized;
}

String? _normalizeFormatId(Object? formatId) {
  if (formatId is! String) {
    return null;
  }
  final String normalized = formatId.trim().toLowerCase();
  return normalized.isEmpty ? null : normalized;
}
