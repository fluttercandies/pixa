# pixa_fetcher_s3

Official Pixa S3 fetcher package.

Use this package when images live in AWS S3 or an S3-compatible object store and
you want them to enter Pixa through the same request, cache, scheduler,
redaction, retry, and runtime-only fetcher path as other sources.

## Install

```yaml
dependencies:
  pixa_fetcher_s3: ^1.0.0
```

```yaml
dependencies:
  pixa: ^1.0.0
  pixa_fetcher_s3: ^1.0.0
```

```yaml
dependencies:
  pixa_fetcher_s3:
    path: ../pixa_fetcher_s3

dependency_overrides:
  pixa:
    path: ../pixa
```

This package re-exports `package:pixa/pixa.dart`, so apps that only use S3
helpers can import `package:pixa_fetcher_s3/pixa_fetcher_s3.dart`.

## Register

Register the plugin during app startup:

```dart
await Pixa.configure(
  const PixaConfig(
    plugins: <PixaPlugin>[
      PixaS3FetcherPlugin(),
    ],
  ),
);
```

The runtime source kinds are `s3` and `s3-object`.

## Use

Create a widget directly:

```dart
PixaS3.image(
  bucket: 'gallery-assets',
  key: 'users/42/avatar.jpg',
  region: 'us-east-1',
  credentials: const PixaS3Credentials(
    accessKeyId: 'AKIA...',
    secretAccessKey: '...',
  ),
  width: 96,
  height: 96,
  fit: BoxFit.cover,
)
```

Use `PixaS3.provider` when a Flutter API expects an `ImageProvider`:

```dart
Image(
  image: PixaS3.provider(
    bucket: 'gallery-assets',
    key: 'photos/hero.jpg',
    region: 'us-east-1',
    credentials: credentials,
    targetWidth: 800,
  ),
)
```

Build a request when you need lower-level control:

```dart
final request = PixaS3.request(
  bucket: 'gallery-assets',
  key: 'photos/hero.jpg',
  region: 'us-east-1',
  credentials: credentials,
  cachePolicy: const PixaCachePolicy.private(),
  priority: PixaPriority.high,
);
```

## Credentials And Privacy

`PixaS3.source` stores only the bucket and object key in the runtime plugin
locator. AWS access keys, secret keys, session tokens, custom endpoints, and
path-style settings are passed as request headers consumed by the Rust runtime
host.

Pixa redacts S3 credential headers in cache labels, logs, observer events, safe
errors, and `PixaDebugSnapshot.toDiagnosticString()`. Keep private or
authenticated objects on a private cache policy unless your product explicitly
allows persistent private disk cache.

## S3-Compatible Storage

Pass `endpoint` and `forcePathStyle` for S3-compatible stores:

```dart
final image = PixaS3.image(
  bucket: 'gallery-assets',
  key: 'photos/hero.jpg',
  region: 'auto',
  endpoint: Uri.parse('https://object-store.example.com'),
  forcePathStyle: true,
  credentials: credentials,
);
```

## Runtime Boundary

This package registers a descriptor for Pixa's shared runtime host. It does not
add a Dart HTTP client, a second cache, or a separate scheduler. Requests use
`PixaPluginExecutionPolicy.runtimeOnly()` by default, so unsupported runtime
configuration fails as a typed Pixa failure instead of silently falling back to a
different transport.

## Diagnostics

Use the standard Pixa diagnostics for support reports:

```dart
final snapshot = PixaDebugInspector.snapshot();
debugPrint(snapshot.toDiagnosticString());
```

The diagnostic output is redacted and should not include raw credentials.
