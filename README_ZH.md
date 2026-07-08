# Pixa

Pixa 是面向生产环境的 Flutter 图片加载库，支持 Android、iOS、macOS、
Windows 和 Linux。它提供熟悉的 Flutter API，底层由同一套 Rust runtime
pipeline 处理请求规范化、加载、encoded memory/disk cache、processed variant、
in-flight 合并、调度、重试、进度、取消、资源限制、观测和插件路由。

Web 不在当前支持矩阵内。Pixa 针对原生 Flutter 应用、平台缓存目录、
Native Assets、Rust IO 以及 Flutter decoded `ImageCache` 做设计。

[English](README.md)

## 快速开始

首个公开版本发布前，可以在本仓库内通过 workspace path 使用：

```yaml
dependencies:
  pixa:
    path: packages/pixa
```

应用启动时配置一次：

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

## 产品 API

当 CDN 提供多种宽度或 MIME 版本时，使用 `PixaSourceSet` 和
`PixaResponsiveImage`。source set 会按布局宽度和 DPR 选择最小足够候选源，并把
target size 纳入 request cache identity。

使用 `PixaCacheWarmupManifest` 和 `Pixa.warmup` 可以预热启动页、首屏图库或离线图库
图片，并得到逐项 success/failure report。

使用 `PixaImageAnalysis` 或 `Pixa.analyze(request)` 可以通过 Rust runtime 计算
average color、dominant color 和小型 palette，用于 placeholder、surface 或诊断，
不引入 Dart 侧第二套 decoder。

## 仓库结构

Git remote：`git@github.com:fluttercandies/pixa.git`

Workspace package 和 runtime crate：

- `packages/pixa`：核心库与公开 API。
- `packages/pixa_fetcher_s3`：官方 S3 fetcher descriptor package。
- `examples/pixa_gallery`：真实网络图库 example 和 cockpit 验收应用。
- `rust/pixa_core`：安全 Rust pipeline、cache、transport、metadata、processor
  和 plugin host 逻辑。
- `rust/pixa_runtime`：Flutter native asset runtime ABI 和生成的 plugin module
  table。

## 架构模型

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

Pixa 负责网络、文件、asset、bytes、cache、调度、metadata、processor、资源限制、
取消和 observer。Flutter 的 `ImageCache` 继续作为 decoded image cache，所以 Pixa
不会再造一套互相冲突的 decoded cache。

Runtime plugin 共享同一个 host runtime、binary ABI、cache、scheduler、progress
和 cancellation 模型。纯 Dart plugin 只在 request 显式 opt-in 时启用，默认图库热路径
保持单 runtime。

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

海量图片快速滚动时，不要无限提高并发。更稳的方式是限制 network/runtime 并发，
保持 Flutter decode 并发较低，并用 `maxImageCompletionsPerFrame` 控制每帧释放给
Flutter 的图片完成数量，避免一批 cache hit 在同一帧触发大量 decoded image 上传。

## Cache 和 Prefetch

Pixa 的缓存栈会让可见图片、prefetch、provider 和大图 tile 共享工作：

- in-flight request coalescing
- Rust encoded memory cache
- Rust encoded disk cache
- processed variant cache
- Flutter decoded `ImageCache`

`Pixa.prefetch` 和 `PixaPredictivePrefetcher` 使用与可见请求相同的 request key
和 variant key。可见请求与 prefetch 重叠时，runtime 只执行一次源加载并共享结果。

## 图库性能

高频滚动路径保持有界和可复用：

- request cache key 在 request 对象内 memoize
- format route 和 runtime capability 查询已 memoize
- rapid scroll 时 prefetch planning 会 lazy skip 旧 generation
- recent prefetch dedupe 使用 recency set 淘汰
- image completion 通过 frame-aware gate 分帧释放
- 大图 tile 共享相同 origin cache 与 in-flight work

低频路径保留更完整的诊断信息：`PixaDebugInspector`、typed failure、benchmark
report 和 platform evidence report。

## 大图

`PixaLargeImage.network` 支持可缩放大图和 adaptive tile planning。小图可以走
direct overview；大图只有在 runtime capability matrix 声明对应格式具备 region
能力时才规划 tile request。Tile request 复用 Pixa request model、scheduler、
encoded cache、processed variant cache、cancellation 和 observer。

## Processor

`PixaProcessors` 为 Rust runtime processor chain 生成稳定 descriptor。公开 helper
覆盖 resize、exact resize、resize-to-fill、center-crop、thumbnail、exact thumbnail、
crop、tile crop/resize、rotate、blur、fast blur、unsharpen、filter3x3、flip、
grayscale、invert、brighten、contrast 和 hue rotate。处理结果会作为 processed
variant 缓存，并复用同一个 origin cache。

## 支持格式

当前公开 display 支持 JPEG、PNG、GIF/animated GIF、WebP/animated WebP、BMP、
WBMP 和 ICO。runtime-backed stable raster matrix 在 capability matrix 声明真实
decoder 能力时还覆盖 TIFF、PNM、QOI、TGA、DDS、HDR、Farbfeld、PCX、SGI、XBM
和 XPM。

未进入声明矩阵的格式会返回 typed unsupported error。只有稳定 decoder、fixtures、
pixel/golden tests、resource limits、capability detection、benchmark coverage
和平台证据齐全后，才会进入公开支持矩阵。

## 插件

插件通过 `PixaConfig(plugins: [...])` 和 `PixaRegistry` 注册。默认图库热路径使用
共享 runtime host。Native fetcher、decoder、processor 和 cache store 必须保持
runtime-owned buffer、binary message、cancellation、progress、observer event
和同一套 cache/scheduler。纯 Dart plugin 支持显式 opt-in 请求。
插件作者如果要在自己的仓库发布 package，应参考
[packages/pixa/PLUGIN_AUTHORING.md](packages/pixa/PLUGIN_AUTHORING.md)。该文档覆盖
package layout、`pubspec.yaml`、`PixaPlugin`、兼容版本范围、应用接入、pub.dev
发布命令、Pure Dart mode、Standalone FFI mode，以及应用通过 Pixa runtime manifest
显式选择的 Host-merge mode。

## Example Gallery

`examples/pixa_gallery` 是用于学习 Pixa 的生产级 Gallery Workbench。Gallery
表面像真实图库应用一样展示 live network feed、flexbox rows、masonry、dense grid、
predictive prefetch、稳定 tile fitting、placeholder/error/retry 和大图入口。Learn
表面按生产任务展示 `PixaImage`、`PixaProvider`、`PixaController`、
`Pixa.pipeline.load`、source 类型、cache policy、decoded prewarm、progressive
preview event、animated GIF/WebP、runtime processor、video-frame capability gate
和 failure recovery。Runtime 表面展示 cache、decoded `ImageCache`、scheduler、
format、plugin、platform 和 runtime capability 状态。

运行静态 example gate：

```bash
melos bootstrap
melos run example
```

本机运行 macOS app：

```bash
cd examples/pixa_gallery
flutter run -d macos
```

## 开发

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

## 发布前检查

本地发布门禁：

```bash
dart run tool/pixa_release_preflight.dart --dry-run
melos run release:preflight
```

完整 preflight 会执行 Dart fix、format、analyze、Flutter tests、Rust fmt/clippy/tests、
architecture guard、platform self-check、gallery example analyze、cockpit acceptance
和 benchmark smoke。

当前 package manifest 仍保持禁止发布，直到 release owner 切首个公开版本。发布到
pub.dev 前，需要选择公开版本、明确移除 package-level publish block、补齐最终发布
metadata，并通过完整 preflight 和 CI。

## 用户文档

英文用户文档见 [packages/pixa/README.md](packages/pixa/README.md)，覆盖 quick start、
图库性能策略、高级 request、cache policy、隐私行为、插件 contract、支持格式、
runtime platform support、release preflight、稳定性策略、迁移策略和 example gallery。

中文用户文档见 [packages/pixa/README_ZH.md](packages/pixa/README_ZH.md)。
