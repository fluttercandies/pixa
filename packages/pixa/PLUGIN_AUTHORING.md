# Pixa Plugin Authoring

This guide is for developers who want to publish a Pixa plugin from their own
repository and let application developers opt into it through Pixa.

For third-party packages, the stable public entry point is a Dart or Flutter
package that depends on `pixa`, implements `PixaPlugin`, and registers
descriptors through `PixaRegistry`. Publishing a package to pub.dev does not
silently inject native code into Pixa's shared Rust host. Native runtime
integration is a separate app-selected build-time step.

In short: packages publish plugin descriptors; apps opt in with
`PixaConfig(plugins: [...])`; host-linked runtime modules require the root app
to provide a Pixa runtime manifest.

For packages that ship more than one integration path, use automatic integration selection through `PixaRegistry.registerAdaptiveIntegration` and
`PixaPluginIntegrationCandidate`. The plugin still has one public
`PixaPlugin` entry point, but registration picks exactly one available
candidate during `Pixa.configure`: runtime host first, then platform channel,
then Pure Dart, then external/standalone FFI. The selected candidate is recorded
in `adaptivePluginIntegrations` diagnostics; unselected candidates do not
register routes and cannot conflict with the selected route plan.

## Choose an integration mode

Pixa 1.0.0 supports five practical integration choices. Pick the smallest one
that matches the cost and ownership of your plugin.

| Mode | Use it when | How the app opts in |
| --- | --- | --- |
| Pure Dart mode | Your handler is light, uses Dart APIs, wraps app-specific bytes, or is mainly for testing/debugging. | Add the package, register `PixaPlugin`, and use a request policy that permits Dart execution. |
| Platform channel mode | Your handler calls MethodChannel, EventChannel, Pigeon, or Flutter platform plugin APIs and returns bounded encoded image data. | Register a platform descriptor with `PixaPlatformContract`, then use `PixaPluginExecutionPolicy.runtimeFirstWithPlatform()` for requests that may cross that boundary. |
| Standalone FFI mode | Your package owns a native SDK or library and can load it with normal Flutter native assets, platform plugin code, or `dart:ffi`. | Expose a Pixa Dart handler that calls your native code, register it with `PixaConfig(plugins: [...])`, and opt into Dart/external cost explicitly. |
| Host-merge mode | The plugin must run in Pixa's image hot path and share Pixa's runtime, cache, scheduler, cancellation, progress, and owned-buffer ABI. | The root app points Pixa's build hook at a `plugin_manifest` or `plugin_manifest_directory`. |
| Asset module mode | You need an explicit dynamic runtime boundary and the Pixa release you target documents that boundary for your platform. | Treat it as advanced integration, not the default 1.0.0 third-party path. |

Adaptive registration is not a sixth execution mode. It is a selection helper
for published pub packages that can offer several of the modes above without
asking app authors to swap plugin classes manually.

The important boundary is ownership. Pub packages can provide Dart code,
tests, README instructions, and optional manifest files. The root app decides
whether any native module is merged into Pixa's host binary because Native
Assets user defines are read from the app or workspace `pubspec.yaml`, not from
a transitive dependency.

The Dart integration path is identical whether the app depends on the plugin
from pub.dev, a local `path`, a `git` dependency, or a workspace package: the
app still constructs the plugin object and passes it to
`PixaConfig(plugins: [...])`. Dependency source only changes development and
publishing discipline; it does not change runtime route selection or host
runtime linking rules.

Official packages follow the same boundary. `pixa_video_frame_mjpeg` ships
`PixaMjpegVideoFramePlugin`, `PixaMjpegVideoFrame.request`,
`PixaMjpegVideoFrame.image`, and `pixa_plugin.json` for the
`pixa.video_frame.mjpeg` host-linked runtime module. Core Pixa keeps only the
video-frame source, request, descriptor, and typed unsupported behavior; it does
not expose the MJPEG manifest from `packages/pixa/plugins/optional`.
Applications must register the Dart plugin and explicitly select the package
manifest with `plugin_manifest` or `plugin_manifest_directory` before the
`video-frame:mjpeg` route can run in the shared host. The plugin uses
`hostRuntimeAvailable`; keep it false until the root app has selected the
manifest, then register `PixaMjpegVideoFramePlugin(hostRuntimeAvailable: true)`.
Core Pixa does not expose the MJPEG manifest from its optional manifest
directory.

## Third-party plugin package layout

Use a standalone package in your own repository:

```text
my_pixa_fetcher/
├── pubspec.yaml
├── README.md
├── CHANGELOG.md
├── LICENSE
├── lib/
│   └── my_pixa_fetcher.dart
└── test/
    └── my_pixa_fetcher_test.dart
```

Keep plugin ids and route names stable. A published id is part of the public
contract because applications may use it in debug tooling, cache routing, and
failure reports.

## pubspec.yaml

Depend on a published Pixa version range. Public pub.dev packages should not
depend on a local path or a git checkout of Pixa.

```yaml
name: my_pixa_fetcher
description: Pixa fetcher for my-image-source objects.
version: 1.0.0
repository: https://github.com/example/my_pixa_fetcher

environment:
  sdk: ">=3.11.0 <4.0.0"
  flutter: ">=3.41.9"

dependencies:
  flutter:
    sdk: flutter
  pixa: ^1.0.0

dev_dependencies:
  flutter_test:
    sdk: flutter
```

If your plugin uses platform channels, native assets, or platform-specific
tooling for its own work, declare those in the plugin package in the normal
Flutter way. Do not assume that those native pieces are part of Pixa's shared
Rust runtime.

## Implement PixaPlugin

Every plugin exposes one small object:

```dart
library;

import 'dart:typed_data';

import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_plugins.dart';

const String myPixaFetcherPluginId = 'com.example.pixa.fetcher.my_source';
const String myPixaFetcherDescriptorId = 'com.example.pixa.fetcher.my_source';

final class MyPixaFetcherPlugin implements PixaPlugin {
  const MyPixaFetcherPlugin();

  @override
  String get id => myPixaFetcherPluginId;

  @override
  PixaVersionConstraint get compatiblePixaVersions =>
      const PixaVersionConstraint(
        minimumInclusive: '1.0.0',
        maximumExclusive: '2.0.0',
      );

  @override
  void register(PixaRegistry registry) {
    registry.registerFetcher(const _MyFetcherDescriptor());
  }
}

final class _MyFetcherDescriptor implements PixaDartFetcherDescriptor {
  const _MyFetcherDescriptor();

  @override
  String get id => myPixaFetcherDescriptorId;

  @override
  PixaPluginExecutionKind get executionKind => PixaPluginExecutionKind.dart;

  @override
  Set<String> get sourceKinds => const <String>{'my-source'};

  @override
  PixaFetcher get fetcher => const _MyFetcher();
}

final class _MyFetcher implements PixaFetcher {
  const _MyFetcher();

  @override
  Future<PixaBytePayload> fetch(
    PixaSource source,
    PixaExecutionContext context,
  ) async {
    context.cancellationSignal.throwIfCancellationRequested();
    if (source is! PixaCustomSource) {
      throw PixaFailure(
        requestId: context.requestId,
        stage: PixaStage.fetch,
        safeMessage: 'Unsupported source for my-source fetcher.',
        retryability: PixaRetryability.notRetryable,
      );
    }

    final Uint8List bytes = await source.loader();
    return PixaBytePayload(bytes: bytes, mimeType: 'image/png');
  }
}
```

Use typed `PixaFailure` values for expected failures. Keep `safeMessage`
redacted: never include tokens, cookies, credentials, signed URLs, or local
private paths.

## Consumer integration

Applications install your package next to Pixa:

```yaml
dependencies:
  pixa: ^1.0.0
  my_pixa_fetcher: ^1.0.0
```

Then they register the plugin before loading images:

```dart
await Pixa.configure(
  const PixaConfig(
    plugins: <PixaPlugin>[
      MyPixaFetcherPlugin(),
    ],
  ),
);
```

Dart fetchers run for source types that the Dart side owns. This is the Pure
Dart mode. For a custom fetcher, the app typically creates a custom source:

```dart
final PixaRequest request = PixaRequest(
  source: PixaSource.custom('my-source', () async {
    return loadMyEncodedImageBytes();
  }),
  pluginExecutionPolicy: const PixaPluginExecutionPolicy.runtimeFirstWithDart(),
);
```

The explicit `runtimeFirstWithDart()` policy matters because it declares that
the request allows a Dart plugin boundary and keeps final cache identity
separate from runtime-only variants. Pixa's default network/file/gallery paths
remain runtime-only unless the app chooses a Dart-owned source or policy.

## Automatic integration selection

A published plugin can expose one stable plugin object and let Pixa choose the
best registered implementation at configuration time. This is the recommended
shape when a package supports a runtime host module for apps that enable a Pixa
manifest, a platform-channel implementation for mobile platforms, and a Pure
Dart fallback for tests or low-cost sources.

```dart
final class MyAdaptiveFetcherPlugin implements PixaPlugin {
  const MyAdaptiveFetcherPlugin({
    this.hostRuntimeAvailable = false,
    this.platformAvailable = true,
  });

  final bool hostRuntimeAvailable;
  final bool platformAvailable;

  @override
  String get id => 'com.example.pixa.fetcher.adaptive';

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
          id: 'runtime-host',
          packageName: 'my_pixa_fetcher',
          hostRuntimeAvailable: hostRuntimeAvailable,
          unavailableMessage:
              'Enable plugin_manifest or plugin_manifest_directory in the root app.',
          register: _registerRuntimeHostFetcher,
        ),
        PixaPluginIntegrationCandidate.platformChannel(
          id: 'platform-channel',
          packageName: 'my_pixa_fetcher',
          platformAvailable: platformAvailable,
          register: _registerPlatformFetcher,
        ),
        PixaPluginIntegrationCandidate.pureDart(
          id: 'dart',
          packageName: 'my_pixa_fetcher',
          register: _registerDartFetcher,
        ),
      ],
    );
  }
}

void _registerRuntimeHostFetcher(PixaRegistry registry) {
  registry.registerFetcher(const MyRuntimeFetcherDescriptor());
}

void _registerPlatformFetcher(PixaRegistry registry) {
  registry.registerFetcher(const MyPlatformFetcherDescriptor());
}

void _registerDartFetcher(PixaRegistry registry) {
  registry.registerFetcher(const MyDartFetcherDescriptor());
}
```

Selection happens once during `Pixa.configure`. Pixa sorts available candidates
by priority; the default priority order is runtime host, platform channel, Pure
Dart, and external/standalone FFI. Only the selected candidate invokes its
registrar, so unavailable runtime routes cannot collide with the platform or
Dart fallback. The compiled route plan and `PixaDebugInspector` diagnostics show
the selected entry under `adaptivePluginIntegrations`.

The selected registrar must register at least one fetcher, decoder, processor,
or cache store descriptor, and every descriptor it adds must match the candidate mode. A `runtimeHost` candidate must add runtime descriptors, a
`platformChannel` candidate must add platform descriptors, a `pureDart`
candidate must add Dart descriptors, and an `external` candidate must add
external descriptors. Pixa rolls back the candidate registration and fails
during configuration if this contract is violated.

Use `requiredIntegration: true` only when a specific candidate is mandatory and
fallback would be incorrect. For example, a decoder that must use the Pixa host
ABI can make the runtime-host candidate required. Pixa will fail during
configuration with the candidate's safe `unavailableMessage` instead of silently
registering a slower or less capable path.

Do not default `hostRuntimeAvailable` to true in a public pub package. A
pub.dev package cannot auto-link runtime host code into the root app. Set it to
true only when the root app has enabled the matching manifest and the plugin's
README tells the app owner which manifest path and native artifacts are being
selected. Platform and Dart candidates may be available from the package itself,
but requests must still opt into their execution boundary with
`PixaPluginExecutionPolicy.runtimeFirstWithPlatform()`,
`PixaPluginExecutionPolicy.runtimeFirstWithDart()`, or
`PixaPluginExecutionPolicy.withExternal(...)`.

## Platform channel mode

Platform channel mode is for platform-owned capabilities that should still use
Pixa request normalization, cache keys, scheduler backpressure, cancellation,
observer events, and typed failures. A descriptor declares
`PixaPluginExecutionKind.platform`, implements `PixaPlatformFetcherDescriptor`,
and provides a `PixaPlatformContract` with channel name, supported platforms,
concurrency, cancellation support, background-queue behavior, hot-path safety,
and optional output byte limits.

The handler may call MethodChannel, EventChannel, Pigeon, or native Flutter
plugin APIs internally. It must return through Pixa's payload contract, usually
`PixaPayloadKind.encodedImage` with a bounded `Uint8List`. Large objects should
use a runtime host module or a documented handle path instead of moving
multi-megabyte data across the UI isolate repeatedly.

```dart
final class MyPlatformFetcherDescriptor
    implements PixaPlatformFetcherDescriptor {
  const MyPlatformFetcherDescriptor();

  @override
  String get id => 'com.example.pixa.fetcher.platform_source';

  @override
  PixaPluginExecutionKind get executionKind =>
      PixaPluginExecutionKind.platform;

  @override
  Set<String> get sourceKinds => const <String>{'platform-source'};

  @override
  PixaPlatformContract get platform => const PixaPlatformContract(
        channel: 'com.example.pixa/platform_source',
        supportedPlatforms: <PixaHostPlatform>{
          PixaHostPlatform.android,
          PixaHostPlatform.ios,
        },
        maxConcurrentCalls: 2,
        supportsCancellation: true,
        backgroundQueue: true,
        hotPathSafe: false,
        maxOutputBytes: 4 * 1024 * 1024,
      );

  @override
  PixaFetcher get fetcher => const MyPlatformFetcher();
}
```

Requests must opt in explicitly:

```dart
final request = PixaRequest(
  source: PixaSource.custom('platform-source', () async {
    throw UnsupportedError('registered platform fetcher required');
  }),
  pluginExecutionPolicy:
      const PixaPluginExecutionPolicy.runtimeFirstWithPlatform(),
);
```

During `Pixa.configure`, Pixa builds a compiled route plan from the registry.
The plan records source-kind routes, decoder MIME and signature routes,
processor operations, cache namespaces, execution lanes, and the platform capability matrix.
The scrolling hot path uses that precompiled lookup; it does
not linearly scan plugins or query platform channels for capability per tile.
A cache hit, processed variant hit, or decoded prewarm hit must not cross the
platform boundary again.

Only mark `hotPathSafe: true` after benchmark evidence for visible gallery use.
Most platform channel mode integrations should keep hot-path safety false and
use them for explicit content providers, media-library thumbnails, secure local
SDK fetchers, or app-owned system services.

## Standalone FFI mode

Standalone FFI mode means the plugin package owns its native binary and loading
strategy. From Pixa's point of view, the executable boundary is still a
Dart-facing handler unless the plugin is also merged into the Pixa host.

Use this mode for native SDKs, platform services, prebuilt libraries, or
license boundaries that should stay outside Pixa's shared Rust runtime. The
plugin can call `dart:ffi`, Flutter platform plugin code, or another package's
native assets internally, then return a `PixaBytePayload` or processor/decoder
result through a normal Pixa descriptor.

Recommended shape:

- Keep the Pixa descriptor as `PixaPluginExecutionKind.dart` when Pixa calls a
  Dart wrapper that then calls your FFI layer.
- Use `PixaPluginExecutionPolicy.runtimeFirstWithDart()` on requests that may
  call the wrapper.
- Reserve `PixaPluginExecutionKind.external` for descriptors that intentionally
  declare an out-of-host boundary. The app must opt in with
  `PixaPluginExecutionPolicy.withExternal(...)`, and your package must document
  the cost and failure behavior.
- Do not claim shared-runtime cache, scheduler, stream-handle, cancellation, or
  zero-copy behavior unless the same native code is also integrated through
  Host-merge mode.

Standalone FFI is the right answer when native ownership matters more than
being on Pixa's default image hot path.

## Host-merge mode

Host-merge mode links a runtime module into Pixa's final host binary at app
build time. This is the path for production fetchers, decoders, processors, or
cache stores that need Pixa's shared runtime and hot-path guarantees.

The app owner enables it from the root app or workspace `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    pixa:
      plugin_manifest: native/pixa_plugin.json
      # Or point at a directory containing one or more JSON manifests:
      # plugin_manifest_directory: native/pixa_plugins/
```

Paths are resolved relative to the `pubspec.yaml` that declares the user
define. `plugin_manifest` is for one manifest. `plugin_manifest_directory` is
for a set of manifests; Pixa scans JSON files deterministically and tracks the
directory as a build dependency so adding or removing a manifest invalidates the
build hook cache.

Example manifest:

```json
{
  "schema": 1,
  "modules": [
    {
      "moduleId": "com.example.pixa.decoder.my_codec",
      "packageName": "my_pixa_codec",
      "deployment": "hostLinkedPluginModule",
      "abiVersion": 1,
      "implementationLanguage": "rust",
      "entrypointSymbol": "com_example_pixa_decoder_init",
      "capabilities": ["decoder"],
      "decoderMimeTypes": ["image/x-my-codec"],
      "decoderCapabilities": {
        "metadataProbe": true,
        "staticDecode": true,
        "animatedDecode": false,
        "progressiveDecode": false,
        "regionDecode": false,
        "processorInput": true,
        "streamingInput": true,
        "defaultRuntimeDisplay": false,
        "zeroCopyInput": true,
        "ownedOutputBuffers": true,
        "stable": true
      },
      "hostManagedRuntime": true,
      "binaryMessages": true,
      "ownedBuffers": true,
      "streamHandles": true,
      "link": {
        "searchPaths": ["native/build"],
        "staticLibraries": ["my_pixa_decoder"]
      }
    }
  ]
}
```

`link.searchPaths` entries are resolved relative to the manifest file. Route
claims must be unique across all built-in, optional, and user-provided modules.
Duplicate source kinds, MIME routes, format ids, decoder signatures, processor
operations, or cache namespaces fail during the build plan, not at first image
load.

Host-merge mode requires the native library to expose the declared
`entrypointSymbol` and obey Pixa runtime ABI version 1: host-managed runtime,
binary messages, owned output buffers, stream handles, explicit cancellation,
bounded errors, and safe redaction. A pub.dev dependency cannot add this root
app configuration on its own.

## Asset module mode

`PixaRuntimeContract.assetModule` and manifest `deployment: "assetModule"` are
reserved for an explicit runtime asset boundary. The manifest model validates
the shape, `assetId`, and entrypoint, but third-party authors should not treat
asset modules as the default Pixa 1.0.0 publishing path. Prefer Pure Dart mode
or Standalone FFI mode for separately owned native binaries, and Host-merge mode
for native code that must share Pixa's hot path.

## Runtime module limits

`PixaRuntimeContract.hostLinkedPluginModule` and `assetModule` describe native
runtime module shapes, but publishing a pub.dev package does not make Pixa link
that module into the shared Rust host.

For Pixa 1.0.0:

- Built-in modules are owned by the Pixa package and its generated build plan.
- Optional native modules require explicit manifest/build-plan integration by
  the app and platform evidence.
- A third-party package can publish a runtime descriptor for validation and
  diagnostics, but apps should not rely on it being executable unless the Pixa
  release they target documents that exact runtime integration.

If your plugin needs native image decoding, region decoding, or heavy pixel
processing today, keep the public package as an opt-in Dart/external descriptor
and coordinate a separate Pixa runtime-host integration before advertising it as
a default hot-path runtime module.

## Publishing

Before publishing your plugin, run:

```bash
dart format .
dart analyze
flutter test
dart pub publish --dry-run
dart pub publish
```

For a Flutter package, run the same commands from the plugin package root. The
package should include `README.md`, `CHANGELOG.md`, and `LICENSE`, and it should
not leave `publish_to: none` in `pubspec.yaml` when publishing to pub.dev.

Public package dependencies should resolve from pub.dev or the Flutter SDK.
Local `path` dependencies and git dependencies are useful during development,
but they are not appropriate for a public plugin release.

## Compatibility and breaking changes

Use `PixaVersionConstraint` to describe the Pixa core versions your plugin
supports:

```dart
const PixaVersionConstraint(
  minimumInclusive: '1.0.0',
  maximumExclusive: '2.0.0',
)
```

Widen the range only after testing against the new Pixa version. If you change a
plugin id, source kind, MIME route, processor operation, cache namespace, output
contract, or failure semantics, treat it as a breaking changes release for your
plugin.

Recommended release discipline:

- Keep plugin ids reverse-DNS or package-scoped.
- Keep source kinds and processor operations lowercase and stable.
- Add tests for registration, route conflicts, cache-key privacy, cancellation,
  and safe error messages.
- Document whether each handler is runtime, Dart, platform, or external.
- Do not claim default runtime-hot-path support unless a Pixa runtime build plan
  actually links and verifies the module.
