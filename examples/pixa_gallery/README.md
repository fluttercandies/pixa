# Pixa Gallery Example

This example app is the fastest way to see Pixa in a real Flutter surface. It
runs on Android, iOS, macOS, Windows, and Linux with live network image sources.
Web is intentionally out of scope for Pixa.

## Run

From the repository root:

```bash
melos bootstrap
cd examples/pixa_gallery
flutter run -d macos
```

Use another supported native device id for Android, iOS, Linux, or Windows:

```bash
flutter devices
flutter run -d <device-id>
```

## What To Try

- Browse real paginated image feeds.
- Compare grid, masonry, and dense scrolling surfaces.
- Watch placeholder, progress, retry, and error states.
- Open low-resolution to full-resolution image examples.
- Trigger predictive prefetch and cache-only requests.
- Inspect cache stats and memory trim controls.
- Try runtime processor examples.
- Open progressive JPEG, animated GIF, and animated WebP examples.
- Use `PixaProvider` in Flutter image APIs.
- Open `PixaLargeImage` for tile-based zoom viewing.
- Check runtime, plugin, scheduler, cache, and platform diagnostics.

## Notes For App Developers

This example is intentionally closer to a product workbench than a minimal demo.
Use it to understand how Pixa behaves under scrolling, repeated requests,
prefetch overlap, cache hits, failures, and resource limits.

If you only need the smallest integration snippet, start from the package README
in `packages/pixa/README.md`.
