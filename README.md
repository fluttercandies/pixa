# Pixa

Pixa is a production-oriented Flutter image loading library for Android, iOS,
macOS, Windows, and Linux. It provides familiar Flutter APIs backed by one
Rust runtime pipeline for request normalization, loading, encoded memory and
disk cache, processed variants, in-flight coalescing, scheduling, retry,
progress, cancellation, resource limits, observability, and plugin routing.

Web is outside the current support matrix. Pixa is optimized for native Flutter
apps, platform cache directories, Native Assets, Rust IO, and Flutter's decoded
`ImageCache`.

[中文文档](README_ZH.md)

## Quick Start

Add Pixa from the package when the first public release is cut, or use the
workspace package path while developing this repository:

```yaml
dependencies:
  pixa:
    path: packages/pixa
```

Configure Pixa once during app startup:

```dart
await Pixa.configure(const PixaConfig(
  memoryCacheBytes: 96 * 1024 * 1024,
  diskCacheBytes: 512 * 1024 * 1024,
  networkConcurrency: 6,
  decodeConcurrency: 2,
));
```

Use `PixaImage.network` where a Flutter app would usually use
`Image.network`:

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

## Product APIs

Use `PixaSourceSet` with `PixaResponsiveImage` when a CDN exposes multiple
candidate widths or MIME variants. The source set picks the smallest candidate
that satisfies layout width and device pixel ratio, then keeps target size in
the request cache identity.

Use `PixaCacheWarmupManifest` with `Pixa.warmup` to prefetch startup, first
viewport, or offline-gallery images and receive per-entry success/failure
reports.

Use `PixaImageAnalysis` or `Pixa.analyze(request)` to get runtime-computed
average color, dominant color, and a small palette for placeholders, surfaces,
or diagnostics without adding a Dart-side decoder.

## Repository

Git remote: `git@github.com:fluttercandies/pixa.git`

Workspace packages and runtime crates:

- `packages/pixa`: core library and public API.
- `packages/pixa_fetcher_s3`: official S3 fetcher descriptor package.
- `examples/pixa_gallery`: real-network gallery example with cockpit acceptance.
- `rust/pixa_core`: safe Rust pipeline, cache, transport, metadata, processor,
  and plugin host logic.
- `rust/pixa_runtime`: Flutter native asset runtime ABI and generated plugin
  module table.

## Architecture Model

```text
PixaImage / Image(image: PixaProvider)
        ↓
PixaController / PixaProvider
        ↓
PixaPipeline
        ↓
request key → in-flight coalescing → scheduler
        ↓
encoded memory cache → encoded disk cache → fetch → decode/process
        ↓
Flutter ImageStream / ImageCache
```

Pixa owns network, file, asset, bytes, cache, scheduling, metadata, processor,
limits, cancellation, and observer behavior. Flutter's `ImageCache` remains the
decoded image cache, so decoded images are not duplicated by a separate Pixa
decoded cache.

Runtime plugins share the same host runtime, binary ABI, cache, scheduler,
progress, and cancellation model. Pure Dart plugins are supported only through
explicit request policy, so the default gallery hot path stays on the single
runtime path.

## Production Configuration

Dense galleries should use explicit budgets:

```dart
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

Keep network and runtime concurrency bounded, keep Flutter decode concurrency
low, and pace image completions so a burst of cache hits cannot push hundreds
of decoded images into one frame.

## Cache And Prefetch

Pixa's cache stack is designed to share work across visible image widgets,
prefetch, provider users, and large-image tiles:

- in-flight request coalescing
- Rust encoded memory cache
- Rust encoded disk cache
- processed variant cache
- Flutter decoded `ImageCache`

`Pixa.prefetch` and `PixaPredictivePrefetcher` reuse the same request keys and
variant keys as visible requests. When a visible request and a prefetch overlap,
the runtime performs one source load and shares the result.

## Gallery Performance

The high-frequency scrolling path is kept bounded and memoized:

- request cache keys are memoized per request object
- format route and runtime capability lookup are memoized
- prefetch planning lazily skips stale generations during rapid scrolls
- recent prefetch dedupe uses recency-set eviction
- image completions are released behind a frame-aware gate
- large-image tiles share the same origin cache and in-flight work

Low-frequency paths keep richer diagnostics through `PixaDebugInspector`,
typed failures, benchmark reports, and platform evidence reports.

## Large Images

`PixaLargeImage.network` supports zoomable large images with adaptive tile
planning. Smaller images can use a direct overview path; large sources can use
tile requests when the runtime capability matrix reports region support for
that format. Tile requests reuse Pixa's request model, scheduler, encoded cache,
processed variant cache, cancellation, and observer events.

## Processors

`PixaProcessors` creates stable descriptors for the Rust runtime processor
chain. The public helper set covers resize, exact resize, resize-to-fill,
center-crop, thumbnail, exact thumbnail, crop, tile crop/resize, rotate, blur,
fast blur, unsharpen, filter3x3, flip, grayscale, invert, brighten, contrast,
and hue rotate. Processor output is stored as processed variants and reuses the
same origin cache.

## Supported Formats

Current public display support covers JPEG, PNG, GIF and animated GIF, WebP and
animated WebP, BMP, WBMP, and ICO. The runtime-backed stable raster matrix also
covers TIFF, PNM, QOI, TGA, DDS, HDR, Farbfeld, PCX, SGI, XBM, and XPM when the
runtime capability matrix reports real decoder support.

Formats outside the declared matrix fail with typed unsupported errors until
stable decoders, fixtures, pixel/golden tests, resource limits, capability
detection, benchmark coverage, and platform evidence exist.

## Plugins

Plugins register through `PixaConfig(plugins: [...])` and `PixaRegistry`.
Default gallery hot paths use the shared runtime host. Native fetchers,
decoders, processors, and cache stores must preserve runtime-owned buffers,
binary messages, cancellation, progress, observer events, and the same
cache/scheduler. Pure Dart plugins are supported for explicit opt-in requests.
Plugin authors who publish packages from their own repositories should follow
[packages/pixa/PLUGIN_AUTHORING.md](packages/pixa/PLUGIN_AUTHORING.md). It
covers package layout, `pubspec.yaml`, `PixaPlugin`, compatible version ranges,
consumer setup, pub.dev publishing commands, Pure Dart mode, Standalone FFI
mode, and app-selected Host-merge mode through a Pixa runtime manifest.

## Example Gallery

`examples/pixa_gallery` is the production gallery workbench for learning Pixa.
The Gallery surface behaves like a real image app with live network feeds,
flexbox rows, masonry, dense grid, predictive prefetch, stable tile fitting,
placeholder/error/retry states, and large-image entry. The Learn surface shows
task-based recipes for `PixaImage`, `PixaProvider`, `PixaController`,
`Pixa.pipeline.load`, source types, cache policies, decoded prewarm,
progressive preview events, animated GIF/WebP, runtime processors,
video-frame capability gates, and failure recovery. The Runtime surface exposes
cache, decoded `ImageCache`, scheduler, format, plugin, platform, and runtime
capability state.

Run the static example gate:

```bash
melos bootstrap
melos run example
```

Run the macOS app locally:

```bash
cd examples/pixa_gallery
flutter run -d macos
```

## Development

```bash
melos bootstrap
dart format .
dart analyze
melos run test
cargo fmt --manifest-path rust/Cargo.toml --all --check
cargo clippy --manifest-path rust/Cargo.toml --all-targets --all-features -- -D warnings
cargo test --manifest-path rust/Cargo.toml --all --no-fail-fast
dart run tool/pixa_guard.dart
melos run example
```

## Release Preflight

Release preflight is available as a single local gate:

```bash
dart run tool/pixa_release_preflight.dart --dry-run
melos run release:preflight
```

The full preflight applies Dart fixes, formats sources, analyzes the workspace,
runs Flutter tests, Rust fmt/clippy/tests, architecture guard, platform
self-check, gallery example analyze, cockpit acceptance, and benchmark smoke.

The current package manifests still keep publishing disabled until the release
owner cuts the first public release. Before publishing to pub.dev, choose the
public version, remove the package-level publish block intentionally, add final
release metadata, and run the full preflight plus CI.

## User Documentation

See [packages/pixa/README.md](packages/pixa/README.md) for English user
documentation covering quick start, gallery performance strategy, advanced
requests, cache policy, privacy behavior, plugin contracts, supported formats,
runtime platform support, release preflight, stability policy, migration policy,
and the example gallery.

中文文档见 [packages/pixa/README_ZH.md](packages/pixa/README_ZH.md)。
