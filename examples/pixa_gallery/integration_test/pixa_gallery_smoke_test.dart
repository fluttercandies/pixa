import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_debug.dart';
import 'package:pixa_gallery/main.dart';
import 'package:pixa_gallery/models/image_post.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real gallery example launches and loads loopback images', (
    WidgetTester tester,
  ) async {
    final List<Map<String, Object?>> checks = <Map<String, Object?>>[];
    final Directory cacheRoot = await Directory.systemTemp.createTemp(
      'pixa-example-smoke-',
    );
    final _LoopbackImageServer server = await _LoopbackImageServer.start();
    addTearDown(() async {
      await server.close();
      if (cacheRoot.existsSync()) {
        cacheRoot.deleteSync(recursive: true);
      }
    });

    await Pixa.configure(
      PixaConfig(
        cacheRootPath: cacheRoot.path,
        memoryCacheBytes: 32 * 1024 * 1024,
        diskCacheBytes: 96 * 1024 * 1024,
        networkConcurrency: 4,
        decodeConcurrency: 1,
        maxImageCompletionsPerFrame: 2,
        maxQueuedRuntimeLoads: 64,
        maxQueuedDecodes: 16,
      ),
    );
    final PixaDebugSnapshot snapshot = PixaDebugInspector.snapshot();
    _check(
      checks,
      'runtimePlatformSelfCheck',
      snapshot.platformSelfCheck.passed,
      snapshot.platformSelfCheck.toJson().toString(),
    );

    final PixaPipelineLoad load = await Pixa.pipeline.load(
      PixaRequest.network(
        server.imageUrl(1000),
        cachePolicy: const PixaCachePolicy.noStore(),
      ),
    );
    try {
      _check(checks, 'runtimePipelineLoad', load.bytes.isNotEmpty);
    } finally {
      load.dispose();
    }

    await tester.pumpWidget(
      PixaGalleryApp(initialPosts: server.posts, loadOnStart: false),
    );
    await tester.pump(const Duration(milliseconds: 100));
    _check(
      checks,
      'appLaunch',
      find.text('Network image gallery').evaluate().isNotEmpty,
    );
    _check(
      checks,
      'layoutControls',
      find.text('Flex rows').evaluate().isNotEmpty &&
          find.text('Masonry').evaluate().isNotEmpty &&
          find.text('Grid').evaluate().isNotEmpty,
    );
    _check(
      checks,
      'exampleNavigation',
      find.text('Gallery').evaluate().isNotEmpty &&
          find.text('Scenarios').evaluate().isNotEmpty &&
          find.text('Diagnostics').evaluate().isNotEmpty,
    );

    await tester.ensureVisible(find.text('Masonry'));
    await tester.tap(find.text('Masonry'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.ensureVisible(find.text('Grid'));
    await tester.tap(find.text('Grid'));
    await tester.pump(const Duration(milliseconds: 100));
    await _pumpUntil(tester, () => server.requestCount > 0);
    _check(checks, 'loopbackImageRequest', server.requestCount > 0);

    await tester.pumpWidget(
      PixaGalleryApp(
        initialPosts: server.posts,
        loadOnStart: false,
        initialTab: PixaGalleryTab.scenarios,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await _pumpUntil(
      tester,
      () => find.text('Pixa scenarios').evaluate().isNotEmpty,
    );
    final bool scenarioInitialVisible =
        find.text('Pixa scenarios').evaluate().isNotEmpty &&
        find.text('Display APIs').evaluate().isNotEmpty &&
        find.text('Provider').evaluate().isNotEmpty &&
        find.text('Controller').evaluate().isNotEmpty;
    await _dragUntilVisible(
      tester,
      scrollable: find.byKey(const ValueKey<String>('pixa-scenarios-scroll')),
      target: find.text('Source bundle'),
    );
    final bool sourceScenarioVisible = find
        .text('Source bundle')
        .evaluate()
        .isNotEmpty;
    await _dragUntilVisible(
      tester,
      scrollable: find.byKey(const ValueKey<String>('pixa-scenarios-scroll')),
      target: find.text('Cache policy'),
    );
    final bool cacheScenarioVisible = find
        .text('Cache policy')
        .evaluate()
        .isNotEmpty;
    await _dragUntilVisible(
      tester,
      scrollable: find.byKey(const ValueKey<String>('pixa-scenarios-scroll')),
      target: find.text('Processor lab'),
    );
    final bool processorScenarioVisible = find
        .text('Processor lab')
        .evaluate()
        .isNotEmpty;
    await _dragUntilVisible(
      tester,
      scrollable: find.byKey(const ValueKey<String>('pixa-scenarios-scroll')),
      target: find.text('Metadata'),
    );
    final bool metadataScenarioVisible = find
        .text('Metadata')
        .evaluate()
        .isNotEmpty;
    await _dragUntilVisible(
      tester,
      scrollable: find.byKey(const ValueKey<String>('pixa-scenarios-scroll')),
      target: find.text('Video frame'),
    );
    _check(
      checks,
      'scenarioCatalog',
      scenarioInitialVisible &&
          sourceScenarioVisible &&
          cacheScenarioVisible &&
          processorScenarioVisible &&
          metadataScenarioVisible &&
          find.text('Video frame').evaluate().isNotEmpty,
    );

    await tester.pumpWidget(
      PixaGalleryApp(
        initialPosts: server.posts,
        loadOnStart: false,
        initialTab: PixaGalleryTab.diagnostics,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await _pumpUntil(
      tester,
      () => find.text('Diagnostics').evaluate().isNotEmpty,
    );
    final bool diagnosticsInitialVisible =
        find.text('Diagnostics').evaluate().isNotEmpty &&
        find.text('Runtime').evaluate().isNotEmpty &&
        find.text('Cache').evaluate().isNotEmpty;
    await _dragUntilVisible(
      tester,
      scrollable: find.byKey(const ValueKey<String>('pixa-diagnostics-scroll')),
      target: find.text('Formats and plugins'),
    );
    _check(
      checks,
      'diagnosticsCatalog',
      diagnosticsInitialVisible &&
          find.text('Formats and plugins').evaluate().isNotEmpty,
    );

    await tester.pumpWidget(
      PixaGalleryApp(
        initialPosts: server.posts,
        loadOnStart: false,
        initialTab: PixaGalleryTab.gallery,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final Finder tile = find.byKey(const ValueKey<String>('grid-1'));
    await _pumpUntil(tester, () => tile.evaluate().isNotEmpty);
    if (tile.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        tile,
        220,
        scrollable: find.byWidgetPredicate(
          (Widget widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      );
    }
    if (tile.evaluate().isNotEmpty) {
      await tester.ensureVisible(tile.first);
      await tester.pump(const Duration(milliseconds: 100));
    }
    final Finder tappableTile = tile.hitTestable();
    _check(checks, 'gridTileVisible', tappableTile.evaluate().isNotEmpty);
    if (tappableTile.evaluate().isNotEmpty) {
      await tester.tapAt(tester.getCenter(tappableTile.first));
      await tester.pump();
      await _pumpUntil(
        tester,
        () => find.byType(PixaLargeImage).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 8),
      );
    }
    _check(
      checks,
      'largeViewerRoute',
      find.byType(PixaLargeImage).evaluate().isNotEmpty,
    );
    _check(checks, 'cacheStats', Pixa.cacheStats().memoryBytes >= 0);

    final bool passed = checks.every(
      (Map<String, Object?> check) => check['passed'] == true,
    );
    _writeReport(
      platform: _platform(),
      checks: checks,
      passed: passed,
      snapshot: snapshot,
    );
    await _disposeSmokeWidgetTree(tester);
    expect(passed, isTrue, reason: const JsonEncoder().convert(checks));
  });
}

Future<void> _disposeSmokeWidgetTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  imageCache.clear();
  imageCache.clearLiveImages();
  for (var attempt = 0; attempt < 8; attempt++) {
    if (tester.binding.transientCallbackCount == 0) {
      break;
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _dragUntilVisible(
  WidgetTester tester, {
  required Finder scrollable,
  required Finder target,
  int maxAttempts = 8,
}) async {
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    if (target.evaluate().isNotEmpty) {
      return;
    }
    await tester.drag(scrollable, const Offset(0, -340));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _check(
  List<Map<String, Object?>> checks,
  String name,
  bool passed, [
  String? message,
]) {
  final Map<String, Object?> entry = <String, Object?>{
    'name': name,
    'passed': passed,
  };
  if (message != null) {
    entry['message'] = message;
  }
  checks.add(entry);
}

void _writeReport({
  required String platform,
  required List<Map<String, Object?>> checks,
  required bool passed,
  required PixaDebugSnapshot snapshot,
}) {
  final String reportText = const JsonEncoder.withIndent('  ').convert(
    <String, Object?>{
      'generatedUtc': DateTime.now().toUtc().toIso8601String(),
      'evidence': <String, Object?>{
        'platform': _env('PIXA_EXAMPLE_EVIDENCE_PLATFORM') ?? platform,
        'runnerOs': Platform.operatingSystem,
        'runMode': 'integration-test',
        'deviceId': _env('PIXA_EXAMPLE_EVIDENCE_DEVICE_ID'),
        'deviceKind': _env('PIXA_EXAMPLE_EVIDENCE_DEVICE_KIND'),
        'connection': _env('PIXA_EXAMPLE_EVIDENCE_CONNECTION'),
        'signing': _env('PIXA_EXAMPLE_EVIDENCE_SIGNING'),
      },
      'exampleSmoke': <String, Object?>{
        'platform': platform,
        'passed': passed,
        'checks': checks,
      },
      'capabilities': snapshot.toJson()['capabilities'],
    },
  );
  final String? reportPath = _env('PIXA_EXAMPLE_SMOKE_REPORT');
  if (reportPath != null) {
    try {
      final File report = File(reportPath);
      report.parent.createSync(recursive: true);
      report.writeAsStringSync(reportText);
    } catch (error) {
      // Keep the marker fallback for sandboxed macOS/iOS integration runners.
      // ignore: avoid_print
      print('PIXA_EXAMPLE_SMOKE_REPORT_FILE_WRITE_FAILED:$error');
    }
  }
  // ignore: avoid_print
  print(
    'PIXA_EXAMPLE_SMOKE_REPORT_JSON:'
    '${base64Url.encode(utf8.encode(reportText))}',
  );
}

String _platform() => Platform.operatingSystem.toLowerCase();

String? _env(String name) {
  final String? value = Platform.environment[name];
  return value == null || value.trim().isEmpty ? null : value.trim();
}

final class _LoopbackImageServer {
  _LoopbackImageServer(this._server) {
    _subscription = _server.listen(_handle);
  }

  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _subscription;
  int requestCount = 0;

  static Future<_LoopbackImageServer> start() async {
    return _LoopbackImageServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
  }

  List<ImagePost> get posts => <ImagePost>[
    for (var index = 1; index <= 36; index++)
      ImagePost(
        id: index,
        imageUrl: imageUrl(index),
        width: 1,
        height: 1,
        source: SourceType.nekosia,
      ),
  ];

  String imageUrl(int id) =>
      'http://${InternetAddress.loopbackIPv4.address}:${_server.port}/$id.gif';

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    requestCount += 1;
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('image', 'gif')
      ..headers.contentLength = _minimalGif.length
      ..add(_minimalGif);
    await request.response.close();
  }
}

final Uint8List _minimalGif = Uint8List.fromList(<int>[
  71,
  73,
  70,
  56,
  57,
  97,
  1,
  0,
  1,
  0,
  128,
  0,
  0,
  0,
  0,
  0,
  255,
  255,
  255,
  44,
  0,
  0,
  0,
  0,
  1,
  0,
  1,
  0,
  0,
  2,
  2,
  76,
  1,
  0,
  59,
]);
