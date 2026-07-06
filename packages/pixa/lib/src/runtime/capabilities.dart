import 'package:flutter/foundation.dart';

import '../image_metadata.dart';
import 'runtime_bridge.dart';
import 'runtime_plugin_stats.dart';

/// platform support and load status.
final class PixaRuntimePlatformStatus {
  /// Creates a platform status snapshot.
  const PixaRuntimePlatformStatus({
    required this.platform,
    required this.isWeb,
    required this.isSupportedPlatform,
    required this.runtimeAvailable,
    required this.message,
    this.contract,
  });

  /// Flutter target platform label.
  final String platform;

  /// Whether the current build target is Web.
  final bool isWeb;

  /// Whether Pixa supports this platform.
  final bool isSupportedPlatform;

  /// Whether runtime symbols are loadable.
  final bool runtimeAvailable;

  /// Human-readable status message.
  final String message;

  /// Platform contract required for this platform, when supported.
  final PixaRuntimePlatformContract? contract;

  /// Returns the current platform/runtime load status.
  factory PixaRuntimePlatformStatus.current() {
    final TargetPlatform platform = defaultTargetPlatform;
    final bool supported = !kIsWeb && _isSupportedPlatform(platform);
    return pixaPlatformStatusForProbe(
      isWeb: kIsWeb,
      targetPlatform: platform,
      runtimeAvailable: supported ? PixaRuntimeBridge.isAvailable : false,
    );
  }
}

/// Evaluates platform status from explicit probe inputs.
///
/// This is kept internal to make unsupported-platform behavior testable without
/// weakening the runtime guard or adding a Dart fallback route.
@visibleForTesting
PixaRuntimePlatformStatus pixaPlatformStatusForProbe({
  required bool isWeb,
  required TargetPlatform targetPlatform,
  required bool runtimeAvailable,
}) {
  final String platform = isWeb ? 'web' : targetPlatform.name;
  final bool platformSupported = _isSupportedPlatform(targetPlatform);
  final bool supported = !isWeb && platformSupported;
  if (!supported) {
    return PixaRuntimePlatformStatus(
      platform: platform,
      isWeb: isWeb,
      isSupportedPlatform: false,
      runtimeAvailable: false,
      message: isWeb
          ? 'Pixa does not support Web; use a Flutter platform.'
          : 'Pixa runtime core is not supported on $platform.',
    );
  }
  final PixaRuntimePlatformContract contract =
      PixaRuntimePlatformContract.forPlatform(targetPlatform);
  return PixaRuntimePlatformStatus(
    platform: platform,
    isWeb: false,
    isSupportedPlatform: true,
    runtimeAvailable: runtimeAvailable,
    contract: contract,
    message: runtimeAvailable
        ? 'Pixa runtime core is available on $platform.'
        : 'Pixa runtime symbols are unavailable on $platform.',
  );
}

bool _isSupportedPlatform(TargetPlatform platform) {
  return switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    TargetPlatform.fuchsia => false,
  };
}

/// Production platform contract expected from one Flutter target platform.
final class PixaRuntimePlatformContract {
  /// Creates a platform contract.
  const PixaRuntimePlatformContract({
    required this.platform,
    required this.targetAbis,
    required this.runtimeLibraryLoad,
    required this.symbolResolution,
    required this.threadedRuntime,
    required this.cacheDirectory,
    required this.networkPolicy,
  });

  /// Android platform contract.
  static const PixaRuntimePlatformContract android =
      PixaRuntimePlatformContract(
        platform: 'android',
        targetAbis: <String>['arm64-v8a', 'armeabi-v7a', 'x86_64'],
        runtimeLibraryLoad: true,
        symbolResolution: true,
        threadedRuntime: true,
        cacheDirectory: true,
        networkPolicy: true,
      );

  /// iOS platform contract.
  static const PixaRuntimePlatformContract iOS = PixaRuntimePlatformContract(
    platform: 'iOS',
    targetAbis: <String>[
      'ios-arm64',
      'ios-simulator-arm64',
      'ios-simulator-x64',
    ],
    runtimeLibraryLoad: true,
    symbolResolution: true,
    threadedRuntime: true,
    cacheDirectory: true,
    networkPolicy: true,
  );

  /// macOS platform contract.
  static const PixaRuntimePlatformContract macOS = PixaRuntimePlatformContract(
    platform: 'macOS',
    targetAbis: <String>['macos-arm64', 'macos-x64'],
    runtimeLibraryLoad: true,
    symbolResolution: true,
    threadedRuntime: true,
    cacheDirectory: true,
    networkPolicy: true,
  );

  /// Windows platform contract.
  static const PixaRuntimePlatformContract windows =
      PixaRuntimePlatformContract(
        platform: 'windows',
        targetAbis: <String>['windows-x64'],
        runtimeLibraryLoad: true,
        symbolResolution: true,
        threadedRuntime: true,
        cacheDirectory: true,
        networkPolicy: true,
      );

  /// Linux platform contract.
  static const PixaRuntimePlatformContract linux = PixaRuntimePlatformContract(
    platform: 'linux',
    targetAbis: <String>['linux-x64', 'linux-arm64'],
    runtimeLibraryLoad: true,
    symbolResolution: true,
    threadedRuntime: true,
    cacheDirectory: true,
    networkPolicy: true,
  );

  /// Supported platform contracts.
  static const List<PixaRuntimePlatformContract> supported =
      <PixaRuntimePlatformContract>[android, iOS, macOS, windows, linux];

  /// Returns the platform contract for a Flutter platform.
  factory PixaRuntimePlatformContract.forPlatform(TargetPlatform platform) {
    return switch (platform) {
      TargetPlatform.android => android,
      TargetPlatform.iOS => iOS,
      TargetPlatform.macOS => macOS,
      TargetPlatform.windows => windows,
      TargetPlatform.linux => linux,
      TargetPlatform.fuchsia => throw UnsupportedError(
        'Pixa has no platform contract for fuchsia.',
      ),
    };
  }

  /// Flutter target platform label.
  final String platform;

  /// ABI or architecture labels that must be covered by packaging.
  final List<String> targetAbis;

  /// runtime library must load on this platform.
  final bool runtimeLibraryLoad;

  /// Runtime ABI symbols must resolve on this platform.
  final bool symbolResolution;

  /// Rust/Tokio and processor work must run off the Flutter UI isolate.
  final bool threadedRuntime;

  /// Cache files must live under the platform cache directory.
  final bool cacheDirectory;

  /// Platform network policy must permit configured image transports.
  final bool networkPolicy;

  /// JSON-like representation for validation reports and debug tools.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'platform': platform,
      'targetAbis': targetAbis,
      'runtimeLibraryLoad': runtimeLibraryLoad,
      'symbolResolution': symbolResolution,
      'threadedRuntime': threadedRuntime,
      'cacheDirectory': cacheDirectory,
      'networkPolicy': networkPolicy,
    };
  }
}

/// One runtime platform validation check.
final class PixaRuntimePlatformCheck {
  /// Creates a validation check result.
  const PixaRuntimePlatformCheck({
    required this.name,
    required this.passed,
    required this.required,
    required this.message,
  });

  /// Stable check name.
  final String name;

  /// Whether the check passed.
  final bool passed;

  /// Whether this check is required on the current platform contract.
  final bool required;

  /// Human-readable diagnostic message.
  final String message;

  /// JSON-like representation for debug tools and platform smoke tests.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'name': name,
      'passed': passed,
      'required': required,
      'message': message,
    };
  }
}

/// Runtime platform self-check report.
final class PixaRuntimePlatformSelfCheck {
  /// Creates a platform self-check report.
  const PixaRuntimePlatformSelfCheck({
    required this.platform,
    required this.isWeb,
    required this.isSupportedPlatform,
    required this.passed,
    required this.checks,
  });

  /// Evaluates runtime platform checks from the current capability snapshot.
  factory PixaRuntimePlatformSelfCheck.evaluate({
    required PixaRuntimeCapabilities capabilities,
    required String? cacheRootPath,
  }) {
    final PixaRuntimePlatformStatus status = capabilities.platformStatus;
    final PixaRuntimePlatformContract? contract = status.contract;
    final List<PixaRuntimePlatformCheck> checks = <PixaRuntimePlatformCheck>[
      _platformCheck(
        name: 'runtimeLibraryLoad',
        required: contract?.runtimeLibraryLoad ?? status.isSupportedPlatform,
        passed: status.runtimeAvailable,
        passedMessage: 'runtime library loaded',
        failedMessage: status.message,
      ),
      _platformCheck(
        name: 'symbolResolution',
        required: contract?.symbolResolution ?? status.isSupportedPlatform,
        passed:
            status.runtimeAvailable &&
            capabilities.runtimePluginAbiVersion != null,
        passedMessage: 'runtime ABI symbols resolved',
        failedMessage: 'runtime ABI symbols are unavailable',
      ),
      _platformCheck(
        name: 'threadedRuntime',
        required: contract?.threadedRuntime ?? status.isSupportedPlatform,
        passed: status.runtimeAvailable && capabilities.pixelProcessors,
        passedMessage: 'runtime threaded work capabilities are available',
        failedMessage: 'runtime threaded work capabilities are unavailable',
      ),
      _platformCheck(
        name: 'cacheDirectory',
        required: contract?.cacheDirectory ?? status.isSupportedPlatform,
        passed: cacheRootPath != null && cacheRootPath.trim().isNotEmpty,
        passedMessage: 'cache directory is resolved',
        failedMessage: 'cache directory is not resolved',
      ),
      _platformCheck(
        name: 'networkPolicy',
        required: contract?.networkPolicy ?? status.isSupportedPlatform,
        passed: status.runtimeAvailable && capabilities.httpTransport,
        passedMessage: 'runtime HTTP transport is available',
        failedMessage: 'runtime HTTP transport is unavailable',
      ),
    ];
    return PixaRuntimePlatformSelfCheck(
      platform: status.platform,
      isWeb: status.isWeb,
      isSupportedPlatform: status.isSupportedPlatform,
      passed: checks.every(
        (PixaRuntimePlatformCheck check) => !check.required || check.passed,
      ),
      checks: List<PixaRuntimePlatformCheck>.unmodifiable(checks),
    );
  }

  /// Platform label.
  final String platform;

  /// Whether this report is for Web.
  final bool isWeb;

  /// Whether Pixa supports this platform.
  final bool isSupportedPlatform;

  /// Whether every required check passed.
  final bool passed;

  /// Individual check results.
  final List<PixaRuntimePlatformCheck> checks;

  /// Required checks that failed.
  Iterable<PixaRuntimePlatformCheck> get failedChecks {
    return checks.where((PixaRuntimePlatformCheck check) {
      return check.required && !check.passed;
    });
  }

  /// JSON-like representation for debug tools and platform smoke tests.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'platform': platform,
      'isWeb': isWeb,
      'isSupportedPlatform': isSupportedPlatform,
      'passed': passed,
      'checks': checks
          .map((PixaRuntimePlatformCheck check) => check.toJson())
          .toList(growable: false),
    };
  }
}

PixaRuntimePlatformCheck _platformCheck({
  required String name,
  required bool required,
  required bool passed,
  required String passedMessage,
  required String failedMessage,
}) {
  return PixaRuntimePlatformCheck(
    name: name,
    required: required,
    passed: passed,
    message: passed ? passedMessage : failedMessage,
  );
}

/// Runtime support capabilities for one encoded image format.
final class PixaRuntimeImageFormatCapability {
  /// Creates one image format capability entry.
  const PixaRuntimeImageFormatCapability({
    required this.format,
    required this.sniffing,
    required this.metadata,
    required this.engineDisplay,
    required this.runtimeDisplay,
    required this.processorDecode,
    required this.animated,
    required this.defaultRuntimeDisplay,
    required this.regionDecode,
  });

  /// Encoded image format.
  final PixaImageMetadataFormat format;

  /// Runtime can identify this format from bounded magic/header bytes.
  final bool sniffing;

  /// Runtime can parse dimensions/traits for this format.
  final bool metadata;

  /// Flutter engine display backend supports this format by default.
  final bool engineDisplay;

  /// Runtime RGBA display backend can decode this format for static output.
  final bool runtimeDisplay;

  /// Runtime processor input decode can use this format.
  final bool processorDecode;

  /// Runtime decoder can read a bounded region without full-frame decode.
  final bool regionDecode;

  /// Pixa supports an animated display mode for this format.
  final bool animated;

  /// Ordinary display requests automatically choose runtime display.
  final bool defaultRuntimeDisplay;

  /// JSON-like representation for debug tools.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'format': format.name,
      'sniffing': sniffing,
      'metadata': metadata,
      'engineDisplay': engineDisplay,
      'runtimeDisplay': runtimeDisplay,
      'processorDecode': processorDecode,
      'regionDecode': regionDecode,
      'animated': animated,
      'defaultRuntimeDisplay': defaultRuntimeDisplay,
    };
  }
}

List<PixaRuntimeImageFormatCapability> _decodeImageFormatCapabilities(
  Uint8List bytes,
) {
  if (bytes.length < 6 ||
      bytes[0] != 0x50 ||
      bytes[1] != 0x58 ||
      bytes[2] != 0x46 ||
      bytes[3] != 0x31) {
    throw const FormatException(
      'Invalid runtime image format capability payload.',
    );
  }
  final int count = bytes[4] | (bytes[5] << 8);
  final int expectedLength = 6 + count * 3;
  if (bytes.length != expectedLength) {
    throw const FormatException(
      'Invalid runtime image format capability length.',
    );
  }
  final List<PixaRuntimeImageFormatCapability> capabilities =
      <PixaRuntimeImageFormatCapability>[];
  for (int index = 0; index < count; index += 1) {
    final int offset = 6 + index * 3;
    final int flags = bytes[offset + 1] | (bytes[offset + 2] << 8);
    capabilities.add(
      PixaRuntimeImageFormatCapability(
        format: pixaImageMetadataFormatFromRuntimeCode(bytes[offset]),
        sniffing: flags & 0x0001 != 0,
        metadata: flags & 0x0002 != 0,
        engineDisplay: flags & 0x0004 != 0,
        runtimeDisplay: flags & 0x0008 != 0,
        processorDecode: flags & 0x0010 != 0,
        animated: flags & 0x0020 != 0,
        defaultRuntimeDisplay: flags & 0x0040 != 0,
        regionDecode: flags & 0x0080 != 0,
      ),
    );
  }
  return List<PixaRuntimeImageFormatCapability>.unmodifiable(capabilities);
}

/// Runtime runtime capability snapshot.
final class PixaRuntimeCapabilities {
  /// Creates a capability snapshot.
  const PixaRuntimeCapabilities({
    required this.diskCache,
    required this.httpTransport,
    required this.exifParser,
    required this.pixelProcessors,
    this.runtimePluginAbiVersion,
    this.runtimePluginRegistryStats =
        const PixaRuntimePluginRegistryStats.empty(),
    this.imageFormats = const <PixaRuntimeImageFormatCapability>[],
    this.platformStatus = const PixaRuntimePlatformStatus(
      platform: 'unknown',
      isWeb: false,
      isSupportedPlatform: false,
      runtimeAvailable: false,
      message: 'Pixa platform status has not been probed.',
    ),
  });

  /// Reads capabilities from the runtime bridge.
  factory PixaRuntimeCapabilities.current() {
    final PixaRuntimePlatformStatus status =
        PixaRuntimePlatformStatus.current();
    if (!status.runtimeAvailable) {
      return PixaRuntimeCapabilities(
        diskCache: false,
        httpTransport: false,
        exifParser: false,
        pixelProcessors: false,
        runtimePluginAbiVersion: null,
        imageFormats: const <PixaRuntimeImageFormatCapability>[],
        platformStatus: status,
      );
    }
    final int bits = PixaRuntimeBridge.capabilityBits();
    return PixaRuntimeCapabilities(
      diskCache: bits & 0x01 != 0,
      httpTransport: bits & 0x02 != 0,
      exifParser: bits & 0x04 != 0,
      pixelProcessors: bits & 0x08 != 0,
      runtimePluginAbiVersion: PixaRuntimeBridge.runtimePluginAbiVersion(),
      runtimePluginRegistryStats:
          PixaRuntimeBridge.runtimePluginRegistryStats(),
      imageFormats: _decodeImageFormatCapabilities(
        PixaRuntimeBridge.imageFormatCapabilitiesPayload(),
      ),
      platformStatus: status,
    );
  }

  /// Platform and runtime library load status.
  final PixaRuntimePlatformStatus platformStatus;

  /// Rust-backed disk cache is available.
  final bool diskCache;

  /// Rust-backed HTTP transport is available.
  final bool httpTransport;

  /// Rust-backed EXIF parser is available.
  final bool exifParser;

  /// Rust-backed pixel processors are available.
  final bool pixelProcessors;

  /// runtime plugin host ABI version when runtime symbols are available.
  final int? runtimePluginAbiVersion;

  /// runtime plugin host registry counters.
  final PixaRuntimePluginRegistryStats runtimePluginRegistryStats;

  /// Runtime image format support matrix.
  final List<PixaRuntimeImageFormatCapability> imageFormats;

  /// True when the mandatory runtime core is loaded.
  bool get hasRequiredCore =>
      platformStatus.isSupportedPlatform &&
      platformStatus.runtimeAvailable &&
      diskCache;
}
