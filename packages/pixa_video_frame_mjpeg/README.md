# pixa_video_frame_mjpeg

Official Pixa MJPEG AVI video-frame backend package.

Use this package when an app needs a still image from an MJPEG AVI file and
wants that frame to flow through Pixa's request model, cache, scheduler,
observer events, resource limits, and runtime host. The output MIME contract is
`image/jpeg`, and the runtime source route is `video-frame:mjpeg`.

This package does not bundle a Dart video decoder, FFmpeg/libav, or a second
cache/scheduler. A pub.dev package cannot auto-link runtime host code into the
root app; the app must explicitly enable this package's runtime manifest.

## Install

```yaml
dependencies:
  pixa: ^1.0.0
  pixa_video_frame_mjpeg: ^1.0.0
```

```yaml
dependencies:
  pixa:
    path: ../pixa
  pixa_video_frame_mjpeg:
    path: ../pixa_video_frame_mjpeg
```

## Enable The Runtime Module

Point Pixa's build hook at this package manifest from the root app:

```yaml
hooks:
  user_defines:
    pixa:
      plugin_manifest: path/to/pixa_video_frame_mjpeg/pixa_plugin.json
      # Or place/copy manifests into one directory:
      # plugin_manifest_directory: native/pixa_plugins/
```

`plugin_manifest` and `plugin_manifest_directory` are app-level choices. They
are not read from transitive dependencies.

Keep `hostRuntimeAvailable` false until the manifest is actually enabled. When
it is false, configuration fails fast instead of registering a route that the
host binary does not contain.

## Register

```dart
await Pixa.configure(
  const PixaConfig(
    plugins: <PixaPlugin>[
      PixaMjpegVideoFramePlugin(hostRuntimeAvailable: true),
    ],
  ),
);
```

## Use

Create a request:

```dart
final request = PixaMjpegVideoFrame.request(
  '/videos/camera-roll.avi',
  timestamp: const Duration(seconds: 2),
);
```

Create a widget:

```dart
final image = PixaMjpegVideoFrame.image(
  '/videos/camera-roll.avi',
  timestamp: const Duration(seconds: 2),
  width: 320,
  height: 180,
  fit: BoxFit.cover,
);
```

## Failure Behavior

Pixa returns typed failures when:

- `hostRuntimeAvailable` is false.
- The root app did not enable `pixa_plugin.json`.
- The AVI file is unsupported or does not contain a usable MJPEG frame.
- The requested timestamp cannot be resolved within resource limits.

These failures are observable through normal Pixa error builders, observers,
and `PixaDebugSnapshot.toDiagnosticString()`.
