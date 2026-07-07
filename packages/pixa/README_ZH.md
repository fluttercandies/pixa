# Pixa 中文文档

Pixa 是面向生产环境的 Flutter 图片加载库，支持 Android、iOS、macOS、
Windows 和 Linux。它提供 `PixaImage`、`PixaProvider`、`PixaController`
和 `PixaPipeline`，底层使用同一套 Rust-backed image pipeline 处理请求规范化、
网络/文件/资源/bytes 加载、encoded memory cache、encoded disk cache、
processed variant cache、in-flight 合并、取消、进度、重试、资源限制、观测
和插件路由。

Web 不在当前支持范围内。Pixa 的设计重点是 Flutter 原生平台、平台缓存目录、
Native Assets、Rust IO 和单一 runtime 热路径。

## 快速开始

应用启动时先配置一次：

```dart
await Pixa.configure(const PixaConfig(
  memoryCacheBytes: 96 * 1024 * 1024,
  diskCacheBytes: 512 * 1024 * 1024,
  networkConcurrency: 6,
  decodeConcurrency: 2,
));
```

像使用 `Image.network` 一样使用 `PixaImage.network`：

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

当 Flutter API 需要 `ImageProvider` 时使用 `PixaProvider`：

```dart
Image(
  image: PixaProvider.network(imageUrl, targetWidth: 300),
  fit: BoxFit.cover,
)
```

## 生产配置

图库类应用建议显式配置预算：

```dart
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

面向海量图片快速滚动时，不要无限提高并发。更稳的策略是限制 runtime/network
并发，保持 Flutter decode 并发较低，并用 `maxImageCompletionsPerFrame`
控制每帧释放给 Flutter 的图片完成数量，避免一批 cache hit 在同一帧触发大量
layout、paint 和 GPU upload。

## 高级请求

`PixaRequest` 是 Widget、Provider、prefetch 和底层 pipeline 共用的稳定模型：

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

## 图库性能模型

Pixa 区分高频滚动路径和低频诊断/配置路径。

高频路径保持有界、可复用、少分配：

- `PixaRequest.cacheKey` 和 `encodedCacheKey` 在 request 对象内 memoize。
- 格式路由和 runtime capability 查询在 display selector 热路径内 memoize。
- in-flight coalescing 让可见请求、prefetch 和同图多处显示共享同一次源获取、
  读取、解码和处理。
- predictive prefetch 在快速滚动时 lazy skip 旧 generation，不反复扫描旧队列。
- recent prefetch dedupe 使用 recency set 做近似 O(1) 淘汰，避免高 churn 下
  `removeAt(0)` 这类线性搬移。
- 图片完成通过 frame-aware gate 分帧释放，避免同一帧释放过多 decoded image。

低频路径保留更多信息：

- debug snapshot 暴露 cache、scheduler、format、platform 和 plugin 状态。
- typed failure 保留 stage、retryability 和 safe message。
- release/benchmark 工具输出本地报告，方便发布前审查。

benchmark report 门禁覆盖普通 prefetch planning、rapid-overlap planning、
recent-completion eviction、request key lookup、format route lookup、cache hit、
disk hit、network coalescing、decode/resize、region decode、animation 和 runtime
ABI overhead。

## 缓存策略

Pixa 和 Flutter 的 decoded `ImageCache` 协作，不替代它。完整缓存层级包括：

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
- `noStore` 不写入 Pixa encoded cache。

使用 `Pixa.prefetch` 或 `PixaPredictivePrefetcher` 支持滚动列表预加载。
Prefetch 和可见请求共享 origin key 和 final variant key，重叠时 runtime 最终只做
一次下载/读取/解码/处理。

## 大图

`PixaLargeImage.network` 用于可缩放大图。默认 adaptive tile mode 会对小图走
direct display，对真正大图才规划 tile request。`always` 适合显式验证 tile/ROI，
`never` 适合业务只需要 overview 的场景。

PNG、BMP 和 Farbfeld 具备内置 region decode 能力。JPEG/WebP ROI 只通过显式启用
并验证的 optional native module 提供；如果没有声明可用 ROI 后端，超大 tile-only
请求会 typed fail-fast，不会静默整图 full decode。

## 图片处理

`PixaProcessors` 生成稳定的 Rust processor descriptor。当前 helper 覆盖 resize、
exact resize、resize-to-fill/center-crop、thumbnail、exact thumbnail、crop、
tile crop/resize、rotate、blur、fast blur、unsharpen、filter3x3、flip、
grayscale、invert、brighten、contrast 和 hue rotate。

处理结果写入 processed variant cache，并复用同一个 encoded origin cache、
scheduler、resource limits 和 runtime display selector。

## 隐私与资源限制

Pixa 会对敏感 URL query、authorization header、cookie、signed URL material、
文件路径细节、observer payload 和 safe error message 做脱敏。认证或私有图片默认
不应落盘，除非 request 明确允许 private disk cache。

每个 request 都受 encoded bytes、decoded pixels、animation frame count、
animation duration、processor output bytes、redirect count、connect timeout、
idle timeout 和 total timeout 限制。超限输入会返回 typed `PixaFailure`，不会静默
继续解码。

## 插件

插件通过 `PixaConfig(plugins: [...])` 和 `PixaRegistry` 注册。默认图库热路径使用
`PixaPluginExecutionPolicy.runtimeOnly()`：native fetcher、decoder、processor 和
cache store 必须进入 Pixa 共享 runtime ABI，使用二进制消息、runtime-owned buffer、
stream handle、cancellation、progress、observer event 和同一套 cache/scheduler。

纯 Dart 插件支持显式 opt-in 请求：

```dart
final request = PixaRequest.network(
  imageUrl,
  pluginExecutionPolicy: const PixaPluginExecutionPolicy.runtimeFirstWithDart(),
);
```

decoder plugin 可以声明 MIME route、stable format id、bounded-header byte
signature，以及 metadata probe、region decode、streaming input、zero-copy input、
owned output buffers 和 stability 等 capability。runtime decoder descriptor 如果不稳定
或不满足 ownership contract，会在注册阶段 fail-fast。

## 支持格式

公开 display 支持 JPEG、PNG、GIF/animated GIF、WebP/animated WebP、BMP、WBMP
和 ICO。runtime-backed stable raster matrix 在 capability matrix 声明真实 decoder
能力时还覆盖 TIFF、PNM、QOI、TGA、DDS、HDR、Farbfeld、PCX、SGI、XBM 和 XPM。

高级矢量、相机 raw、文档预览和下一代 codec 格式当前不进入公开支持矩阵。
只有稳定 decoder、fixtures、pixel/golden tests、resource limits、
capability detection、benchmark coverage 和平台证据都齐全后，才会加入公开支持矩阵。
未知格式会返回 typed unsupported error，不会被宣传为已支持。

## 平台支持

当前支持 Android、iOS、macOS、Windows 和 Linux。runtime platform self-check 覆盖
runtime library load、symbol resolution、threaded runtime、cache directory 和 HTTP
transport：

```dart
final snapshot = PixaDebugInspector.snapshot();
print(snapshot.platformSelfCheck?.toJson());
```

本仓库也提供 `melos run platform:self-check` 用于本地 runner 证据。

iOS 和 macOS 同时声明 Swift Package Manager 与 CocoaPods plugin wrapper。
这些 wrapper 只负责注册；图片 runtime 仍由 Native Assets hook 构建，并继续走同一套共享 Rust runtime 路径。

## 发布前检查

发布或切 release branch 前运行：

```bash
dart run tool/pixa_release_preflight.dart --dry-run
melos run release:preflight
```

preflight 会执行 Dart fix、format、analyze、Flutter tests、Rust format、Rust
clippy、Rust tests、architecture guard、platform self-check、platform evidence
self-test、example smoke wrapper self-test、benchmark report self-test、example smoke
和 smoke benchmark report。architecture guard 也会校验 Darwin SwiftPM manifest、
CocoaPods podspec 和 CI SPM build 开关。

## 稳定性策略

稳定公开入口是 `package:pixa/pixa.dart`、`package:pixa/pixa_plugins.dart` 和
`package:pixa/pixa_debug.dart`。内部 runtime binding、generated code、cache internal
和 scheduler internal 都不是 public API。

Pixa 遵循语义化版本。破坏性 public API 修改需要 major version；废弃 API 必须说明
替代方案，并至少保留一个 minor release 后再移除。

## Example Gallery

`examples/pixa_gallery` 展示真实网络请求、grid loading、predictive prefetch、
placeholder/error/retry、low-res 到 high-res、progressive preview、animated GIF/WebP、
cache-only、memory trim、runtime processing、`PixaProvider` 和 `PixaLargeImage`。

运行：

```bash
melos bootstrap
melos run example
```
