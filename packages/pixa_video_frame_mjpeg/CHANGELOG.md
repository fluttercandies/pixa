# Changelog

## 1.0.0

- Initial public release of the official Pixa MJPEG video-frame runtime plugin
  package.
- Adds `PixaMjpegVideoFrame.request`, `PixaMjpegVideoFrame.image`, the
  `PixaMjpegVideoFramePlugin` registration entrypoint, and the packaged
  `pixa_plugin.json` runtime manifest.
- Pixa's Native Assets hook discovers the packaged runtime manifest directly
  from the resolved dependency graph; no app-owned vendoring is required.
