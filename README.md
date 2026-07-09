<p align="center">
  <img src="packages/pixa/assets/brand/pixa-lockup.svg" alt="Pixa logo" width="420">
</p>

# Pixa

Pixa is a production-oriented Flutter image loading library for Android, iOS,
macOS, Windows, and Linux. It gives app code familiar Flutter surfaces such as
`PixaImage`, `PixaProvider`, `PixaController`, and `PixaRequest`, while the
heavy work runs through one Rust-backed pipeline for loading, caching,
processing, scheduling, cancellation, progress, and diagnostics.

Web is not part of the current support matrix. Pixa is designed for native
Flutter apps, Native Assets, platform cache directories, and Flutter's decoded
`ImageCache`.

[中文文档](README_ZH.md)

## Install

```yaml
dependencies:
  pixa: ^1.0.0
```

```yaml
dependencies:
  pixa:
    path: packages/pixa
```

## Quick Start

Configure Pixa once during app startup:

```dart
await Pixa.configure(const PixaConfig(
  memoryCacheBytes: 96 * 1024 * 1024,
  diskCacheBytes: 512 * 1024 * 1024,
  networkConcurrency: 6,
  decodeConcurrency: 2,
));
```

Use `PixaImage.network` where you would normally use `Image.network`:

```dart
PixaImage.network(
  imageUrl,
  width: 96,
  height: 96,
  fit: BoxFit.cover,
  placeholder: const PixaPlaceholder.color(Color(0xFFEDEFF2)),
  errorBuilder: (context, error, retry) {
    return IconButton(
      icon: const Icon(Icons.refresh),
      onPressed: retry,
    );
  },
)
```

Use `PixaProvider` when a Flutter API expects an `ImageProvider`:

```dart
Image(
  image: PixaProvider.network(imageUrl, targetWidth: 300),
  fit: BoxFit.cover,
)
```

## What You Get

- Widget, provider, controller, prefetch, and low-level pipeline entry points.
- Shared in-flight work so repeated requests do not repeat source loading.
- Encoded memory cache, encoded disk cache, processed variant cache, and
  Flutter decoded `ImageCache` cooperation.
- Retry, progress, cancellation, timeouts, resource limits, and typed failures.
- Runtime image processors and large-image tile planning.
- Redacted diagnostics through `PixaDebugSnapshot.toDiagnosticString()` and
  `PixaLogObserver`.
- A plugin model for runtime, Dart, platform, and external integrations.

Common source helpers are symmetric across request, provider, and widget APIs:
`PixaRequest.asset`, `PixaRequest.bytes`, `PixaRequest.custom`,
`PixaProvider.custom`, `PixaImage.runtimePlugin`, and source-set candidates for
file, asset, and runtime-plugin sources all reuse the same request model.

## Product APIs

Use `PixaSourceSet` with `PixaResponsiveImage` when a CDN exposes multiple
candidate widths or MIME variants. Use `PixaCacheWarmupManifest` with
`Pixa.warmup` to prefetch startup, first-viewport, or offline-gallery images.
Use `PixaImageAnalysis` or `Pixa.analyze(request)` to compute average color,
dominant color, and a small palette for placeholders or diagnostics.

For dense galleries, set explicit budgets instead of relying on device defaults:

```dart
await Pixa.configure(const PixaConfig(
  memoryCacheBytes: 160 * 1024 * 1024,
  diskCacheBytes: 1024 * 1024 * 1024,
  networkConcurrency: 6,
  decodeConcurrency: 2,
  maxImageCompletionsPerFrame: 3,
  maxQueuedRuntimeLoads: 256,
  maxQueuedDecodes: 32,
));
```

## Official Plugins

The official S3 package exposes `PixaS3.provider` and `PixaS3.image` so S3
objects enter the same runtime-only fetcher path without placing credentials in
locators or cache labels.

Video-frame extraction uses the same plugin boundary. Core Pixa exposes request
helpers and typed unsupported failures, but it does not ship a default video-frame backend.
The official MJPEG backend lives in
`pixa_video_frame_mjpeg`; apps register
`PixaMjpegVideoFramePlugin(hostRuntimeAvailable: true)` only after explicitly
enabling that package's `pixa_plugin.json` through `plugin_manifest` or
`plugin_manifest_directory`.

Plugin authors should start with
[packages/pixa/PLUGIN_AUTHORING.md](packages/pixa/PLUGIN_AUTHORING.md). It
explains package layout, consumer setup, Pure Dart mode, platform channel mode,
Standalone FFI mode, and app-selected Host-merge mode. A pub.dev package cannot auto-link runtime host code into Pixa's shared runtime just by being added as a transitive dependency.

Advanced plugins can use
`PixaPluginExecutionPolicy.runtimeFirstWithPlatform()` for explicit platform
opt-in. Pixa builds a compiled route plan during `Pixa.configure`, including the
platform capability matrix, so gallery hot paths do not scan plugin descriptors
per tile. Plugins with multiple boundaries can use
`PixaPluginIntegrationCandidate` and
`PixaRegistry.registerAdaptiveIntegration` for automatic integration selection;
the selected result is reported through `adaptivePluginIntegrations`.

## Example App

`examples/pixa_gallery` is the main hands-on demo. It shows real network image
feeds, placeholder/progress/error/retry states, predictive prefetch, cache-only
loading, runtime processors, animated images, large-image viewing, diagnostics,
and plugin capability gates.

Run it locally:

```bash
melos bootstrap
cd examples/pixa_gallery
flutter run -d macos
```

Use another supported native device id for Android, iOS, Linux, or Windows.

## Documentation Map

- [packages/pixa/README.md](packages/pixa/README.md): package user guide.
- [packages/pixa/README_ZH.md](packages/pixa/README_ZH.md): Chinese package
  guide.
- [packages/pixa_fetcher_s3/README.md](packages/pixa_fetcher_s3/README.md):
  official S3 fetcher package.
- [packages/pixa_video_frame_mjpeg/README.md](packages/pixa_video_frame_mjpeg/README.md):
  official MJPEG video-frame backend package.
- [examples/pixa_gallery/README.md](examples/pixa_gallery/README.md): example
  app guide.

## Development Checks

Before sending changes through review, run the local gates that match the
change:

```bash
dart fix --apply
dart format .
dart analyze
dart run tool/pixa_guard.dart
melos run test
```

Release preflight is available as:

```bash
dart run tool/pixa_release_preflight.dart --dry-run
melos run release:preflight
```
