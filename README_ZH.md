<p align="center">
  <img src="packages/pixa/assets/brand/pixa-lockup.svg" alt="Pixa logo" width="420">
</p>

# Pixa

Pixa 是面向生产环境的 Flutter 图片加载库，支持 Android、iOS、macOS、
Windows 和 Linux。应用侧使用熟悉的 `PixaImage`、`PixaProvider`、
`PixaController` 和 `PixaRequest`，加载、缓存、处理、调度、取消、进度和诊断等重
任务走同一条 Rust-backed pipeline。

Web 不在当前支持矩阵内。Pixa 针对原生 Flutter 应用、Native Assets、平台缓存目录
和 Flutter decoded `ImageCache` 设计。

[English](README.md)

## 安装

```yaml
dependencies:
  pixa: ^1.0.0
```

Pixa 需要 Flutter 3.38.1 或更高版本（Dart 3.10.0 或更高版本）。正常执行
`flutter pub get` 即可。支持的 Flutter 版本默认启用 Native Assets，无需
Flutter feature flag、hook 配置、manifest 复制或 path override。

### Native 构建前置条件

Pixa 通过 Flutter Native Assets 编译包内 Rust runtime。首次 Flutter 构建前安装宿主
支持的 Rust toolchain：

```bash
rustup toolchain install stable --profile minimal
```

跨平台构建还需要对应 target 的 Rust standard library 和 native compiler。缺少 target
时 build hook 会输出准确的 `rustup target add` 命令。Windows JPEG Turbo ROI 构建需要
Visual Studio C++ workload 和 NASM；Android 构建需要 Android NDK、SDK CMake 和
Ninja。

## 快速开始

应用启动时配置一次：

```dart
import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';

Future<void> main() async {
  await Pixa.configure(const PixaConfig(
    memoryCacheBytes: 96 * 1024 * 1024,
    diskCacheBytes: 512 * 1024 * 1024,
    networkConcurrency: 6,
    decodeConcurrency: 2,
  ));
  runApp(const App());
}
```

`App` 代表应用的根 Widget。`Pixa.configure` 会在需要时自行初始化 Flutter
binding，不需要额外调用 binding 初始化 API。

像使用 `Image.network` 一样使用 `PixaImage.network`：

```dart
import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';

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

当 Flutter API 需要 `ImageProvider` 时使用 `PixaProvider`：

```dart
import 'package:flutter/material.dart';
import 'package:pixa/pixa.dart';

Image(
  image: PixaProvider.network(imageUrl, targetWidth: 300),
  fit: BoxFit.cover,
)
```

## 你会得到什么

- Widget、provider、controller、prefetch 和底层 pipeline 入口。
- in-flight 合并，重复请求不会重复执行源加载。
- encoded memory cache、encoded disk cache、processed variant cache，并与
  Flutter decoded `ImageCache` 协作。
- retry、progress、cancellation、timeout、resource limits 和 typed failure。
- runtime image processor 和大图 tile planning。
- 通过 `PixaDebugSnapshot.toDiagnosticString()` 和 `PixaLogObserver` 输出脱敏诊断。
- runtime、Dart、platform 和 external 集成边界清晰的插件模型。

常见 source helper 在 request、provider 和 widget API 之间保持对称：
`PixaRequest.asset`、`PixaRequest.bytes`、`PixaRequest.custom`、
`PixaProvider.custom`、`PixaImage.runtimePlugin`，以及 file、asset、
runtime-plugin source-set candidate 都复用同一个 request model。

## 产品 API

当 CDN 提供多种宽度或 MIME 版本时，使用 `PixaSourceSet` 和
`PixaResponsiveImage`。使用 `PixaCacheWarmupManifest` 和 `Pixa.warmup` 可以预热
启动页、首屏图库或离线图库图片。使用 `PixaImageAnalysis` 或
`Pixa.analyze(request)` 可以计算 average color、dominant color 和小型 palette，
用于 placeholder 或诊断。

图库类应用建议显式配置预算：

```dart
import 'package:pixa/pixa.dart';

await Pixa.configure(const PixaConfig(
  memoryCacheBytes: 160 * 1024 * 1024,
  diskCacheBytes: 1024 * 1024 * 1024,
  networkConcurrency: 6,
  decodeConcurrency: 2,
  maxImageCompletionsPerFrame: 3,
  maxQueuedRuntimeLoads: 256,
  maxQueuedDecodes: 32,
));
```

## 官方插件

官方 S3 package 提供 `PixaS3.provider` 和 `PixaS3.image`，让 S3 object 通过同一条
runtime-only fetcher 路径进入 Pixa，凭据不会写入 locator 或 cache label。

Video-frame 抽帧也走同一套插件边界。Pixa core 提供 request helper 和 typed
unsupported failure，但不内置默认 video-frame backend。官方 MJPEG backend 位于
`pixa_video_frame_mjpeg`；添加依赖后，Pixa Native Assets hook 会从已解析 package
graph 自动发现该包的 `pixa_plugin.json`，应用只需在 `PixaConfig` 中注册
`PixaMjpegVideoFramePlugin()`。

插件作者请从 [packages/pixa/PLUGIN_AUTHORING.md](packages/pixa/PLUGIN_AUTHORING.md)
开始。文档说明 package layout、应用接入、Pure Dart mode、platform channel mode、
Standalone FFI mode，以及从已解析 package graph 自动发现的 host-linked module。

高级插件可以用 `PixaPluginExecutionPolicy.runtimeFirstWithPlatform()` 显式 opt in
平台边界。`Pixa.configure` 会生成 compiled route plan 和 platform capability matrix，
图库热路径不会在每个 tile 扫描插件 descriptor。支持多个执行边界的插件可以用
`PixaPluginIntegrationCandidate` 和
`PixaRegistry.registerAdaptiveIntegration` 做 automatic integration selection；
选择结果会写入 `adaptivePluginIntegrations` 诊断。

## 示例应用

`examples/pixa_gallery` 是主要上手示例，覆盖真实网络图片流、
placeholder/progress/error/retry、predictive prefetch、cache-only、runtime
processor、动画图片、大图查看、诊断和插件能力门禁。

本机运行：

```bash
melos bootstrap
cd examples/pixa_gallery
flutter run -d macos
```

Android、iOS、Linux 或 Windows 使用对应的原生 device id。

## 文档导航

- [packages/pixa/README_ZH.md](packages/pixa/README_ZH.md)：核心包中文用户手册。
- [packages/pixa/README.md](packages/pixa/README.md)：核心包英文用户手册。
- [packages/pixa_fetcher_s3/README.md](packages/pixa_fetcher_s3/README.md)：官方 S3
  fetcher package。
- [packages/pixa_video_frame_mjpeg/README.md](packages/pixa_video_frame_mjpeg/README.md)：
  官方 MJPEG video-frame backend package。
- [examples/pixa_gallery/README.md](examples/pixa_gallery/README.md)：示例应用说明。

## 开发检查

提交或评审前按改动范围运行：

```bash
dart fix --apply
dart format .
dart analyze
dart run tool/pixa_guard.dart
melos run test
```

发布前检查：

```bash
dart run tool/pixa_release_preflight.dart --dry-run
melos run release:preflight
```
