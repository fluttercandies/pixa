# Pixa

Pixa is a production-oriented Flutter image loading library for Android, iOS,
macOS, Windows, and Linux. It provides `PixaImage`, `PixaProvider`,
`PixaController`, and `PixaPipeline` on top of one Rust-backed image pipeline for
request normalization, network/file/asset/bytes loading, encoded memory cache,
encoded disk cache, processed variants, in-flight coalescing, cancellation,
progress, retry, resource limits, observability, and plugin routing.

Web is not part of this package target. Pixa is designed around native Flutter
platforms, platform cache directories, native assets, Rust IO, and a single
runtime hot path.

## Quick Start

Configure Pixa once before loading images:

```dart
await Pixa.configure(const PixaConfig(
  memoryCacheBytes: 96 * 1024 * 1024,
  diskCacheBytes: 512 * 1024 * 1024,
  networkConcurrency: 6,
  decodeConcurrency: 2,
));
```

Use `PixaImage.network` where you would usually use `Image.network`:

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

## Production Configuration

Start with explicit budgets instead of relying on device defaults:

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

For dense galleries, tune budgets from the screen shape and image size. Keep
network/runtime concurrency bounded, keep Flutter decode concurrency low, and
pace image completions so a burst of cache hits cannot upload hundreds of
decoded images in one frame.

Use `PixaProvider` when a Flutter API expects an `ImageProvider`:

```dart
Image(
  image: PixaProvider.network(imageUrl, targetWidth: 300),
  fit: BoxFit.cover,
)
```

## Advanced Request

`PixaRequest` is the stable model used by widgets, providers, prefetch, and the
lower-level pipeline:

```dart
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

Use `PixaLargeImage.network` for zoomable large images. It plans visible tiles
and near-viewport prefetch tiles through the same pipeline, so original encoded
bytes, processed tile variants, and in-flight work are shared instead of
duplicated.

## Gallery Performance Model

Pixa separates high-frequency scrolling work from low-frequency diagnostics and
configuration.

High-frequency paths are kept bounded and memoized:

- `PixaRequest.cacheKey` and `encodedCacheKey` are memoized per request object.
- Format route and runtime capability lookup are memoized for display selector
  hot paths.
- In-flight coalescing shares origin fetch/read/decode work across visible
  requests, prefetch, and repeated uses of the same image.
- Predictive prefetch lazily skips stale generations during rapid scrolling
  instead of repeatedly scanning old pending queues.
- Recent prefetch dedupe uses recency-set eviction instead of linear list
  removal under high churn.
- Image completions are released behind a frame-aware gate, so batches of
  completed loads are paced across Flutter frames.

Low-frequency paths keep richer behavior: debug snapshots expose cache,
scheduler, format, platform, and plugin state; typed failures keep stage,
retryability, and safe messages; release tools write local benchmark and
platform reports.

The benchmark report gate covers normal planning, rapid-overlap planning,
recent-completion eviction, request-key lookup, format-route lookup, cache hit,
disk hit, network coalescing, decode/resize, region decode, animation, and
runtime ABI overhead.

## Cache Policy

Pixa cooperates with Flutter's decoded `ImageCache`; it does not replace it.
The complete cache stack is:

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
- `noStore` avoids Pixa encoded cache writes.

Use `Pixa.prefetch` or `PixaPredictivePrefetcher` for scrollable galleries.
Prefetch and visible requests share the same origin and final variant keys, so
the runtime does one download/read/decode/processing step when keys overlap.

## Large Images

Use `PixaLargeImage.network` for zoomable large images. The default adaptive
tile mode uses direct display for smaller images and tile requests only when the
source is large enough to justify region work. `always` is available for
explicit tile validation, and `never` is available when a product only needs a
simple overview.

PNG, BMP, and Farbfeld expose built-in region decode capability. JPEG and WebP
ROI use optional native modules only when the final app explicitly enables and
verifies those modules on its target platforms. Without a declared ROI backend,
oversized tile-only requests fail safely instead of silently full-decoding a huge
image.

## Processors

`PixaProcessors` creates stable processor descriptors for the Rust runtime
processor chain. Supported helpers include resize, exact resize, resize-to-fill
or center-crop, thumbnail, exact thumbnail, crop, tile crop/resize, rotate, blur,
fast blur, unsharpen, filter3x3, flip, grayscale, invert, brighten, contrast,
hue rotate.

Processor output is keyed as a processed variant and reuses the same encoded
origin cache, scheduler, resource limits, and runtime display selector.

## Privacy And Limits

Pixa redacts sensitive URL query values, authorization headers, cookies, signed
URL material, file path details, observer payloads, and safe error messages.
Authenticated or private images should keep `privateDiskCache` disabled unless
the request explicitly allows private disk storage.

Every request is bounded by encoded bytes, decoded pixels, animation frame
count, animation duration, processor output bytes, redirect count, connect
timeout, idle timeout, and total timeout. Oversized or unsafe inputs fail with
typed `PixaFailure` values rather than being silently decoded.

## Plugins

Plugins register through `PixaConfig(plugins: [...])` and `PixaRegistry`.
Default gallery hot paths use `PixaPluginExecutionPolicy.runtimeOnly()`: native
fetchers, decoders, processors, and cache stores must run inside Pixa's shared
runtime ABI with binary messages, runtime-owned buffers, stream handles,
cancellation, progress, observer events, and the same cache/scheduler.

Pure Dart plugins are supported for explicit opt-in requests:

```dart
final request = PixaRequest.network(
  imageUrl,
  pluginExecutionPolicy: const PixaPluginExecutionPolicy.runtimeFirstWithDart(),
);
```

Decoder plugins can declare MIME routes, stable format ids, bounded-header byte
signatures, and capability flags such as metadata probe, region decode,
streaming input, zero-copy input, owned output buffers, and stability. Runtime
decoder descriptors that are not stable or do not preserve the ownership
contract fail during registration.

## Supported Formats

Current public display support covers JPEG, PNG, GIF and animated GIF, WebP and
animated WebP, BMP, WBMP, and ICO. The runtime-backed stable raster matrix also
covers TIFF, PNM, QOI, TGA, DDS, HDR, Farbfeld, PCX, SGI, XBM, and XPM when the
runtime capability matrix reports real decoder support.

Advanced vector, camera raw, document-preview, and next-generation codec
formats remain outside the public support matrix until stable decoders,
fixtures, pixel/golden tests, resource limits, capability detection, benchmark
coverage, and platform evidence exist. Unknown formats fail with typed
unsupported errors instead of being advertised as supported.

## Platform Support

Supported Flutter targets are Android, iOS, macOS, Windows, and Linux. Runtime
platform self-check reports cover library load, symbol resolution, threaded
runtime capability, cache directory resolution, and HTTP transport availability:

```dart
final snapshot = PixaDebugInspector.snapshot();
print(snapshot.platformSelfCheck?.toJson());
```

The repository also includes `melos run platform:self-check` for local runner
evidence.

iOS and macOS declare both Swift Package Manager and CocoaPods plugin wrappers.
The wrappers are registration-only; the image runtime is still built by the
Native Assets hook and stays on the same shared Rust runtime path.

## Release Preflight

Before publishing or cutting a release branch, run:

```bash
dart run tool/pixa_release_preflight.dart --dry-run
melos run release:preflight
```

The preflight applies Dart fixes, formats sources, analyzes the workspace, runs
Flutter tests, Rust formatting, Rust clippy, Rust tests, architecture guard,
platform self-check, platform evidence self-test, example smoke wrapper
self-test, benchmark report self-test, example smoke, and smoke benchmark report
generation. The architecture guard also verifies the Darwin SwiftPM manifests,
CocoaPods podspecs, and CI SPM build switch.

## Stability Policy

The stable public entry points are `package:pixa/pixa.dart`,
`package:pixa/pixa_plugins.dart`, and `package:pixa/pixa_debug.dart`. Internal
runtime bindings, generated code, cache internals, and scheduler internals are
not public API.

Pixa follows semantic versioning. Breaking public API changes require a major
version. Deprecated APIs must name a replacement and remain available for at
least one minor release before removal. Migration examples belong in this README
or the package changelog before a breaking release is cut.

## Example Gallery

`examples/pixa_gallery` demonstrates real network requests, grid loading,
predictive prefetch, placeholder/error/retry states, low-res to high-res
requests, progressive preview, animated GIF/WebP, cache-only loading, memory
trim, runtime processing, `PixaProvider`, and `PixaLargeImage`.

Run:

```bash
melos bootstrap
melos run example
```

Chinese documentation: [README_ZH.md](README_ZH.md).
