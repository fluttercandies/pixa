<p align="center">
  <img src="assets/brand/pixa-lockup.svg" alt="Pixa logo" width="420">
</p>

# Pixa 中文文档

Pixa 是面向生产环境的 Flutter 图片加载库，支持 Android、iOS、macOS、Windows 和
Linux。它提供 `PixaImage`、`PixaProvider`、`PixaController`、`PixaRequest`、
prefetch helper、诊断入口和插件扩展点，底层使用同一条 Rust-backed image
pipeline。

Pixa 面向原生 Flutter 应用；Web 不在当前 package 目标内。

## 安装

```yaml
dependencies:
  pixa: ^1.0.0
```

### Native 构建前置条件

Pixa 使用 Flutter Native Assets 编译包内 Rust runtime。构建依赖 Pixa 的应用前先安装
固定 toolchain：

```bash
rustup toolchain install 1.89.0 --profile minimal
```

跨平台 target 还需要执行 `rustup target add <target> --toolchain 1.89.0` 并安装对应
platform compiler。Rust、Cargo 或 target 缺失时，Native Assets hook 会输出可直接执行
的修复命令。Windows JPEG Turbo ROI 构建需要 Visual Studio 的 Desktop development
with C++ workload 和 NASM。Android 构建需要 Android NDK、SDK CMake 和 Ninja；
Pixa 的 64 位 Android runtime 原生支持 16 KB page size。

## 快速开始

加载图片前先配置一次：

```dart
import 'package:pixa/pixa.dart';

await Pixa.configure(const PixaConfig(
  memoryCacheBytes: 96 * 1024 * 1024,
  diskCacheBytes: 512 * 1024 * 1024,
  networkConcurrency: 6,
  decodeConcurrency: 2,
));
```

普通图片 widget 使用 `PixaImage.network`：

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

## Request 和 Source

`PixaRequest` 是 widget、provider、prefetch 和底层 pipeline 共用的稳定模型：

```dart
import 'package:pixa/pixa.dart';

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

常见 source helper 在 request、provider 和 widget API 之间保持对称：
`PixaRequest.asset`、`PixaRequest.bytes`、`PixaRequest.custom`、
`PixaProvider.custom`、`PixaImage.runtimePlugin`，以及 file、asset、
runtime-plugin source-set candidate 都复用同一个 request model。

## 响应式图片、预热和分析

当 CDN 提供多种宽度或 MIME 版本时，使用 `PixaSourceSet` 和
`PixaResponsiveImage`。候选源选择会把 target size 纳入 request identity，让 cache 和
prefetch 行为保持可预测。

使用 `PixaCacheWarmupManifest` 和 `Pixa.warmup` 可以预热启动页、首屏图库或离线图库，
并得到逐项报告。

使用 `PixaImageAnalysis` 或 `Pixa.analyze(request)` 可以计算 average color、
dominant color 和小型 palette，用于 placeholder、surface 或诊断。

## 生产配置

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
  decodedCacheMaximumSize: 1200,
  decodedCacheMaximumSizeBytes: 180 * 1024 * 1024,
));
```

保持 network/runtime 并发有界，保持 Flutter decode 并发较低，并通过
`maxImageCompletionsPerFrame` 把图片完成分散到多个 frame。

## Cache 和 Prefetch

Pixa 与 Flutter decoded `ImageCache` 协作，不替代它。完整缓存层级包括：

- in-flight request coalescing
- Rust encoded memory cache
- Rust encoded disk cache
- processed variant cache
- Flutter decoded `ImageCache`

`PixaCachePolicy` 控制 encoded cache 行为：

- `memoryAndDisk` 是默认生产策略。
- `memoryOnly` 和 `diskOnly` 限制 encoded bytes 保留位置。
- `cacheOnly` miss 时返回 typed failure，不主动获取。
- `networkOnly` 跳过 cache read，但仍可按策略写入。
- `refresh` 强制重新获取。
- `staleWhileRevalidate` 先返回 stale cache，同时后台刷新。
- `noStore` 不写入 encoded cache。

使用 `Pixa.prefetch` 或 `PixaPredictivePrefetcher` 支持滚动列表预加载。Prefetch 与
可见请求共享 origin key 和 final variant key，重叠时会复用同一份加载结果。

## 大图和图片处理

`PixaLargeImage.network` 用于可缩放大图。默认 adaptive tile mode 会对小图走直接显示，
对真正大图才规划 tile request。

`PixaProcessors` 生成稳定的 runtime processor descriptor，覆盖 resize、center-crop、
thumbnail、crop、tile crop/resize、rotate、blur、unsharpen、filter3x3、flip、
grayscale、invert、brighten、contrast 和 hue rotate。处理结果写入 processed
variant cache，并复用同一个 origin cache、scheduler、resource limits 和 display
selector。

大图 ROI 支持范围会刻意小于通用解码格式矩阵：

- 静态、非交错 PNG 采用顺序逐行解码，同时限制完整 decoded row 和请求区域；APNG
  与交错 PNG 的 tile 请求返回 typed unsupported error。
- Farbfeld 与 WBMP 只读取请求覆盖的 byte/bit rows。
- 可选 Native Assets processor 为 single-scan lossy JPEG 和不透明 lossy VP8 WebP
  提供 decoder-native crop + scaling；JPEG 会在 native crop 前映射 EXIF orientation。
  progressive JPEG、VP8L 和带 alpha 的 WebP 只有在完整 source 隐藏工作集也满足
  request limits 时才允许处理；lossless JPEG 与 animated WebP 不声明 ROI。
- BMP、TIFF、GIF、ICO、PNM、QOI、TGA、DDS、HDR、PCX、SGI、XBM 和 XPM 不声明
  ROI。tile 请求只能走保守预算约束的 full-decode fallback，否则在分配前失败。

只添加版本依赖即可使用 Pixa，不要求 hook 配置。需要可选 JPEG/WebP native ROI
processor 的应用，可以在应用或 workspace root 的 `pubspec.yaml` 中同时启用：

```yaml
hooks:
  user_defines:
    pixa:
      enable_native_roi: true
```

只需要单个 processor 时可分别使用 `enable_jpeg_turbo_roi` 或
`enable_webp_roi`。实际可用性会出现在 runtime plugin capabilities 中，应用无需根据
平台猜测 native support。

## 隐私与资源限制

Pixa 会脱敏敏感 URL query、authorization header、cookie、signed URL material、文件
路径细节、observer payload 和 safe error message。认证或私有图片默认不应写入私有
disk cache，除非 request 明确允许。

每个 request 都受 encoded bytes、decoded pixels、animation frame count、
animation duration、processor output bytes、redirect count、connect timeout、idle
timeout 和 total timeout 限制。超限输入会返回 typed `PixaFailure`，不会静默继续解码。

## 支持格式

公开 display 支持 JPEG、PNG、GIF/animated GIF、WebP/animated WebP、BMP、WBMP 和
ICO。runtime-backed stable raster matrix 在 capability matrix 声明真实 decoder 能力时
还覆盖 TIFF、PNM、QOI、TGA、DDS、HDR、Farbfeld、PCX、SGI、XBM 和 XPM。

未进入声明矩阵的格式会返回 typed unsupported error。只有稳定 decoder、fixtures、
pixel/golden tests、resource limits、capability detection、benchmark coverage 和平台
证据齐全后，才会进入公开支持矩阵。

## 插件

插件通过 `PixaConfig(plugins: [...])` 和 `PixaRegistry` 注册。默认图库热路径使用
`PixaPluginExecutionPolicy.runtimeOnly()`：native fetcher、decoder、processor 和
cache store 都保持在 Pixa 共享 runtime 路径内，并复用同一套 cache、scheduler、
cancellation、progress 和 observer 模型。

纯 Dart 插件只在 request 显式 opt-in 时启用：

```dart
import 'package:pixa/pixa.dart';

final request = PixaRequest.network(
  imageUrl,
  pluginExecutionPolicy: const PixaPluginExecutionPolicy.runtimeFirstWithDart(),
);
```

平台插件通过 `PixaPluginExecutionKind.platform`、`PixaPlatformContract` 和
`PixaPluginExecutionPolicy.runtimeFirstWithPlatform()` 显式 opt in。
`Pixa.configure` 会编译 compiled route plan，包含 source route、decoder route、
processor route、cache namespace、execution lane 和 platform capability matrix。
图库热路径使用预计算 plan，不在每个 tile 扫描插件或查询平台 channel；cache hit 也不会再次跨 Dart/platform/external 插件边界。

发布到 pub.dev 的插件如果支持多个执行边界，可以通过
`PixaPluginIntegrationCandidate` 和
`PixaRegistry.registerAdaptiveIntegration` 做 automatic integration selection。
Pixa 会在 `Pixa.configure` 期间只选择一个可用 candidate，在
`adaptivePluginIntegrations` 中记录结果，并让未选 route 保持不可见。

插件作者请参考 [PLUGIN_AUTHORING.md](PLUGIN_AUTHORING.md)。Pixa Native Assets hook
会从已解析 package graph 自动发现并验证 `pixa_plugin.json`，再把 host module
链接到唯一的 shared runtime。

## 官方插件包

官方 S3 package 提供 `PixaS3.provider` 和 `PixaS3.image`，让 S3 object 通过同一条
runtime-only fetcher 路径进入 Pixa，凭据不会写入 locator 或 cache label。

Video-frame 抽帧也走同一套插件边界。Pixa core 只暴露 `PixaRequest.videoFrame`、
`PixaImage.videoFrame`、backend descriptor 和 typed unsupported failure，但不内置默认 video-frame backend。官方 MJPEG backend 位于 `pixa_video_frame_mjpeg`；添加依赖后 Native Assets hook 会自动发现该包的 `pixa_plugin.json`，应用只需注册 `PixaMjpegVideoFramePlugin()`。

## 诊断

提交 issue 或排查用户问题时，使用脱敏诊断：

```dart
import 'package:flutter/foundation.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';

final snapshot = PixaDebugInspector.snapshot();
debugPrint(snapshot.toDiagnosticString());

await Pixa.configure(const PixaConfig(
  observers: <PixaObserver>[PixaLogObserver()],
));
```

`PixaDebugSnapshot.toDiagnosticString()` 和 `PixaLogObserver()` 不输出原始 authorization
header、signed URL material、private path 或 token。

## 示例应用

`examples/pixa_gallery` 展示真实网络请求、grid loading、predictive prefetch、
placeholder/error/retry、low-res 到 high-res、progressive preview、animated images、
cache-only、memory trim、runtime processing、`PixaProvider` 和 `PixaLargeImage`。

从仓库根目录运行：

```bash
melos bootstrap
cd examples/pixa_gallery
flutter run -d macos
```

## 发布与稳定性

发布或切 release branch 前运行：

```bash
dart run tool/pixa_release_preflight.dart --dry-run
melos run release:preflight
```

稳定公开入口是 `package:pixa/pixa.dart`、`package:pixa/pixa_plugins.dart` 和
`package:pixa/pixa_debug.dart`。内部 runtime binding、generated code、cache internal
和 scheduler internal 都不是 public API。

English documentation: [README.md](README.md).
