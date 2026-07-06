# Pixa Gallery Example

This example demonstrates Pixa with real network image sources on Android,
iOS, macOS, Windows, and Linux.

Covered user-facing flows:

- Real paginated image feeds.
- `PixaImage` and `PixaProvider`.
- Placeholder, progress, retry, and error UI.
- Low-resolution to full-resolution image loading.
- Predictive prefetch and cache-only requests.
- Cache stats and memory trim controls.
- Rust processor watermark example.
- Progressive JPEG, animated GIF, and animated WebP examples.
- `PixaLargeImage` tile-based zoom viewer.

Run it with:

```bash
flutter run -d macos
```

Use another supported native device id for Android, iOS, Linux, or Windows.
Web is intentionally out of scope for Pixa.
