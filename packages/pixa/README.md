<p align="center">
  <img src="assets/brand/pixa-lockup.svg" alt="Pixa logo" width="420">
</p>

# Pixa

Pixa is a production-oriented Flutter image loading library for Android, iOS,
macOS, Windows, and Linux. It provides `PixaImage`, `PixaProvider`,
`PixaController`, `PixaRequest`, prefetch helpers, diagnostics, and plugin
extension points on top of one Rust-backed image pipeline.

Pixa focuses on native Flutter apps. Web is not part of this package target.

## Install

```yaml
dependencies:
  pixa: ^1.0.0
```

### Native build prerequisite

Pixa compiles its packaged Rust runtime with Flutter Native Assets. Install the
pinned toolchain before building an app that depends on Pixa:

```bash
rustup toolchain install 1.89.0 --profile minimal
```

Cross targets also require `rustup target add <target> --toolchain 1.89.0` and
their platform compiler. The Native Assets hook emits an actionable command if
Rust, Cargo, or the requested target is unavailable. Windows JPEG Turbo ROI
builds require Visual Studio with the Desktop development with C++ workload and
NASM. Android builds require the Android NDK, SDK CMake, and Ninja; Pixa's
64-bit Android runtime is linked for native 16 KB page-size support.

## Quick Start

Configure Pixa before loading images:

```dart
import 'package:pixa/pixa.dart';

await Pixa.configure(const PixaConfig(
  memoryCacheBytes: 96 * 1024 * 1024,
  diskCacheBytes: 512 * 1024 * 1024,
  networkConcurrency: 6,
  decodeConcurrency: 2,
));
```

Use `PixaImage.network` for normal image widgets:

```dart
import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';

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

Use `PixaProvider` with Flutter APIs that expect an `ImageProvider`:

```dart
import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';

Image(
  image: PixaProvider.network(imageUrl, targetWidth: 300),
  fit: BoxFit.cover,
)
```

## Requests And Sources

`PixaRequest` is the stable model shared by widgets, providers, prefetch, and
the lower-level pipeline:

```dart
import 'package:pixa/pixa.dart';

final request = PixaRequest.network(
  imageUrl,
  headers: const {'Accept': 'image/webp,image/*,*/*'},
  targetSize: const PixaTargetSize(width: 300, height: 300),
  cachePolicy: const PixaCachePolicy.public(maxAge: Duration(days: 7)),
  priority: PixaPriority.high,
  retryPolicy: const PixaRetryPolicy.exponential(maxAttempts: 3),
  redirectPolicy: const PixaRedirectPolicy(maxRedirects: 5),
);

PixaImage(request: request)
```

Common source helpers are symmetric across request, provider, and widget APIs:
`PixaRequest.asset`, `PixaRequest.bytes`, `PixaRequest.custom`,
`PixaProvider.custom`, `PixaImage.runtimePlugin`, and source-set candidates for
file, asset, and runtime-plugin sources reuse the same request model.

## Responsive Images, Warmup, And Analysis

Use `PixaSourceSet` with `PixaResponsiveImage` when a CDN exposes multiple
candidate widths or MIME variants. The selected candidate keeps target size in
the request identity, so cache and prefetch behavior stays predictable.

Use `PixaCacheWarmupManifest` and `Pixa.warmup` for startup, first-viewport, or
offline-gallery prefetch batches with per-entry reports.

Use `PixaImageAnalysis` or `Pixa.analyze(request)` to compute average color,
dominant color, and a small palette for placeholders, surfaces, or diagnostics.

## Production Configuration

Dense galleries should use explicit budgets instead of relying on device
defaults:

```dart
import 'package:pixa/pixa.dart';

await Pixa.configure(const PixaConfig(
  memoryCacheBytes: 160 * 1024 * 1024,
  diskCacheBytes: 1024 * 1024 * 1024,
  networkConcurrency: 6,
  decodeConcurrency: 2,
  maxImageCompletionsPerFrame: 3,
  maxQueuedRuntimeLoads: 256,
  maxQueuedDecodes: 32,
  decodedCacheMaximumSize: 1200,
  decodedCacheMaximumSizeBytes: 180 * 1024 * 1024,
));
```

Keep network/runtime concurrency bounded, keep Flutter decode concurrency low,
and pace image completions so batches of cache hits are spread across frames.

## Cache And Prefetch

Pixa cooperates with Flutter's decoded `ImageCache`; it does not replace it.
The cache stack is:

- in-flight request coalescing
- Rust encoded memory cache
- Rust encoded disk cache
- processed variant cache
- Flutter decoded `ImageCache`

`PixaCachePolicy` controls encoded cache behavior:

- `memoryAndDisk` is the default production policy.
- `memoryOnly` and `diskOnly` limit where encoded bytes are retained.
- `cacheOnly` returns a typed miss instead of fetching.
- `networkOnly` skips cache reads but can still write by policy.
- `refresh` forces a new source load.
- `staleWhileRevalidate` returns stale cache while refreshing in the background.
- `noStore` avoids encoded cache writes.

Use `Pixa.prefetch` or `PixaPredictivePrefetcher` for scrollable galleries.
Prefetch and visible requests share origin and final variant keys, so overlapping
loads reuse the same work.

## Large Images And Processors

Use `PixaLargeImage.network` for zoomable large images. The adaptive tile mode
uses direct display for smaller images and tile requests only when the source is
large enough to justify region work.

`PixaProcessors` creates stable runtime processor descriptors for resize,
center-crop, thumbnail, crop, tile crop/resize, rotate, blur, unsharpen,
filter3x3, flip, grayscale, invert, brighten, contrast, and hue rotate.
Processor output is cached as a processed variant and reuses the same origin
cache, scheduler, resource limits, and display selector.

Large-image ROI support is deliberately narrower than the general decode
matrix:

- Static, non-interlaced PNG decodes sequential rows while bounding both the
  full decoded row and requested region. APNG and interlaced PNG tile requests
  fail with a typed unsupported error.
- Farbfeld and WBMP read only the requested byte/bit rows.
- Optional Native Assets processors provide decoder-native crop and scaling
  for single-scan lossy JPEG and opaque lossy VP8 WebP. JPEG EXIF orientation
  is mapped before the native crop. Progressive JPEG, VP8L, and WebP with
  alpha are accepted only when their full-source hidden working set fits the
  request limits; lossless JPEG and animated WebP are not advertised as ROI.
- BMP, TIFF, GIF, ICO, PNM, QOI, TGA, DDS, HDR, PCX, SGI, XBM, and XPM do not
  advertise ROI. A tile request uses the conservatively bounded full-decode
  fallback or fails before allocation.

The normal dependency-only setup works without hook configuration. Apps that
want the optional JPEG and WebP native ROI processors can enable both in the
app or workspace-root `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    pixa:
      enable_native_roi: true
```

Use `enable_jpeg_turbo_roi` or `enable_webp_roi` instead when only one native
processor is required. Availability remains visible through runtime plugin
capabilities, so an app never has to infer native support from the platform.

## Privacy And Limits

Pixa redacts sensitive URL query values, authorization headers, cookies, signed
URL material, file path details, observer payloads, and safe error messages.
Authenticated or private images should keep private disk cache disabled unless
the request explicitly allows private disk storage.

Every request is bounded by encoded bytes, decoded pixels, animation frame
count, animation duration, processor output bytes, redirect count, connect
timeout, idle timeout, and total timeout. Oversized or unsafe inputs fail with
typed `PixaFailure` values instead of being silently decoded.

## Supported Formats

Current public display support covers JPEG, PNG, GIF and animated GIF, WebP and
animated WebP, BMP, WBMP, and ICO. The runtime-backed stable raster matrix also
covers TIFF, PNM, QOI, TGA, DDS, HDR, Farbfeld, PCX, SGI, XBM, and XPM when the
runtime capability matrix reports real decoder support.

Formats outside the declared matrix return typed unsupported errors until
stable decoders, fixtures, pixel/golden tests, resource limits, capability
detection, benchmark coverage, and platform evidence exist.

## Plugins

Plugins register through `PixaConfig(plugins: [...])` and `PixaRegistry`.
Default gallery hot paths use `PixaPluginExecutionPolicy.runtimeOnly()`: native
fetchers, decoders, processors, and cache stores stay inside Pixa's shared
runtime path and reuse the same cache, scheduler, cancellation, progress, and
observer model.

Pure Dart plugins are available only for explicit opt-in requests:

```dart
import 'package:pixa/pixa.dart';

final request = PixaRequest.network(
  imageUrl,
  pluginExecutionPolicy: const PixaPluginExecutionPolicy.runtimeFirstWithDart(),
);
```

Platform-channel plugins use `PixaPluginExecutionKind.platform`,
`PixaPlatformContract`, and
`PixaPluginExecutionPolicy.runtimeFirstWithPlatform()`. Pixa compiles a compiled
route plan during configuration, including source routes, decoder routes,
processor routes, cache namespaces, execution lanes, and the platform capability matrix.
Gallery hot paths use that precomputed plan, so they do not scan plugins or
query platform channels per tile; a cache hit does not cross Dart, platform, or
external plugin boundaries again.

Published plugins that support more than one boundary can use automatic integration selection with `PixaPluginIntegrationCandidate` and
`PixaRegistry.registerAdaptiveIntegration`. Pixa selects one available
candidate during `Pixa.configure`, records it in `adaptivePluginIntegrations`,
and keeps unselected routes out of the compiled route plan.

Plugin authors should follow
[PLUGIN_AUTHORING.md](https://github.com/fluttercandies/pixa/blob/main/packages/pixa/PLUGIN_AUTHORING.md).
Pixa's Native Assets hook discovers validated `pixa_plugin.json` manifests
from the resolved package graph and links host modules into one shared runtime.

## Official Plugin Packages

The official S3 package exposes `PixaS3.provider` and `PixaS3.image` helpers so
S3 objects use the same runtime-only fetcher path without leaking credentials in
locators or cache labels.

Video-frame extraction follows the same plugin boundary. Core Pixa exposes
`PixaRequest.videoFrame`, `PixaImage.videoFrame`, backend descriptors, and typed
unsupported failures, but it does not ship a default video-frame backend. The
official MJPEG backend lives in `pixa_video_frame_mjpeg`; apps register
`PixaMjpegVideoFramePlugin()` after adding the package dependency. Its
`pixa_plugin.json` is discovered automatically during Native Assets build.

## Diagnostics

Use redacted diagnostics when filing issues or supporting users:

```dart
import 'package:flutter/foundation.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';

final snapshot = PixaDebugInspector.snapshot();
debugPrint(snapshot.toDiagnosticString());

await Pixa.configure(const PixaConfig(
  observers: <PixaObserver>[PixaLogObserver()],
));
```

`PixaDebugSnapshot.toDiagnosticString()` and `PixaLogObserver()` avoid raw
authorization headers, signed URL material, private paths, and original tokens.

## Example Gallery

`examples/pixa_gallery` demonstrates real network requests, grid loading,
predictive prefetch, placeholder/error/retry states, low-res to high-res
requests, progressive preview, animated images, cache-only loading, memory trim,
runtime processing, `PixaProvider`, and `PixaLargeImage`.

Run from the repository root:

```bash
melos bootstrap
cd examples/pixa_gallery
flutter run -d macos
```

## Release And Stability

Before publishing or cutting a release branch, run:

```bash
dart run tool/pixa_release_preflight.dart --dry-run
melos run release:preflight
```

The stable public entry points are `package:pixa/pixa.dart`,
`package:pixa/pixa_plugins.dart`, and `package:pixa/pixa_debug.dart`. Internal
runtime bindings, generated code, cache internals, and scheduler internals are
not public API.

Chinese documentation:
[README_ZH.md](https://github.com/fluttercandies/pixa/blob/main/packages/pixa/README_ZH.md).
