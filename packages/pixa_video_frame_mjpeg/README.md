# pixa_video_frame_mjpeg

Official Pixa MJPEG AVI video-frame backend package.

Use this package when an app needs a still image from an MJPEG AVI file and
wants that frame to flow through Pixa's request model, cache, scheduler,
observer events, resource limits, and runtime host. The output MIME contract is
`image/jpeg`, and the runtime source route is `video-frame:mjpeg`.

This package does not bundle a Dart video decoder, FFmpeg/libav, or a second
cache/scheduler. Pixa's Native Assets hook discovers this package's
`pixa_plugin.json` from the resolved dependency graph and links the module into
the shared runtime automatically.

## Install

```yaml
dependencies:
  pixa_video_frame_mjpeg: ^1.0.0
```

```yaml
dependencies:
  pixa: ^1.0.0
  pixa_video_frame_mjpeg: ^1.0.0
```

This package re-exports `package:pixa/pixa.dart`, so apps that only use MJPEG
helpers can import `package:pixa_video_frame_mjpeg/pixa_video_frame_mjpeg.dart`.

Run `flutter pub get` normally. No `hooks.user_defines`, copied manifest, or
second dependency-resolution pass is required.

## Register

```dart
import 'package:flutter/material.dart';
import 'package:pixa_video_frame_mjpeg/pixa_video_frame_mjpeg.dart';

Future<void> main() async {
  await Pixa.configure(
    const PixaConfig(
      plugins: <PixaPlugin>[
        PixaMjpegVideoFramePlugin(),
      ],
    ),
  );
  runApp(const App());
}
```

`App` is your application's root widget. No separate Flutter binding
initialization is required.

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

- Native Assets cannot build or load the shared Pixa runtime.
- The AVI file is unsupported or does not contain a usable MJPEG frame.
- The requested timestamp cannot be resolved within resource limits.

These failures are observable through normal Pixa error builders, observers,
and `PixaDebugSnapshot.toDiagnosticString()`.
