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
animated WebP, BMP, WBMP, and ICO. Additional stable raster formats are routed
through the runtime capability matrix only when real decoder support, metadata
probe, resource limits, tests, and benchmark coverage exist.

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
