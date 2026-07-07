# Pixa

Pixa is a Flutter image loading library for Android, iOS, macOS, Windows, and
Linux. It provides a Flutter-native API backed by one Rust runtime pipeline for
request normalization, encoded memory/disk cache, processed variants,
in-flight coalescing, scheduling, network/file/asset/bytes loading, retry,
progress, cancellation, resource limits, observability, and plugin routing.

Web is outside the current support matrix.

Git remote:

```bash
git@github.com:fluttercandies/pixa.git
```

## Packages

- `packages/pixa`: core library and public API.
- `packages/pixa_fetcher_s3`: official S3 fetcher descriptor package.
- `examples/pixa_gallery`: real-network gallery example and smoke app.
- `rust/pixa_core`: safe Rust pipeline, cache, transport, metadata, processor,
  and plugin host logic.
- `rust/pixa_runtime`: Flutter native asset runtime ABI and generated plugin
  module table.

## Architecture

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

Pixa owns network, cache, scheduling, metadata, processor, limits, cancellation,
and observer behavior. Flutter's `ImageCache` remains the decoded image cache.
Runtime plugins share the same host runtime, binary ABI, cache, scheduler,
progress, and cancellation model. Pure Dart plugins are supported only through
explicit request policy.

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

Release preflight is available as a single local gate:

```bash
dart run tool/pixa_release_preflight.dart --dry-run
melos run release:preflight
```

The full preflight applies Dart fixes, formats sources, analyzes the workspace,
runs Flutter tests, Rust fmt/clippy/tests, architecture guard, platform
self-check, example smoke, and benchmark smoke.

## User Documentation

See [packages/pixa/README.md](packages/pixa/README.md) for English user
documentation covering quick start, gallery performance strategy, advanced
requests, cache policy, privacy behavior, plugin contracts, supported formats,
runtime platform support, release preflight, stability policy, migration policy,
and the example gallery.

中文文档见 [packages/pixa/README_ZH.md](packages/pixa/README_ZH.md)。
