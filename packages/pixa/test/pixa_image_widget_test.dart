import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PixaImage renders placeholder while source is unresolved',
      (WidgetTester tester) async {
    await _configure('pixa-widget-placeholder-');
    final Completer<Uint8List> bytes = Completer<Uint8List>();
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('placeholder', () => bytes.future),
      cachePolicy: const PixaCachePolicy.noStore(),
    );

    await tester.pumpWidget(MaterialApp(
      home: PixaImage(
        request: request,
        placeholder: const PixaPlaceholder.widget(
          SizedBox(key: Key('placeholder')),
        ),
      ),
    ));
    await tester.pump();

    expect(find.byKey(const Key('placeholder')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('PixaImage renders decoded image from Flutter ImageCache',
      (WidgetTester tester) async {
    await _configure('pixa-widget-success-');
    const PixaTargetSize layoutTarget = PixaTargetSize(width: 1, height: 1);
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('success', () async {
        throw StateError('decoded cache should satisfy this widget test');
      }),
      cachePolicy: const PixaCachePolicy.noStore(),
    );
    await _seedDecodedCache(tester, request.copyWith(targetSize: layoutTarget));

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 1),
        child: PixaImage(width: 1, height: 1, request: request),
      ),
    ));

    await _pumpUntil(tester, find.byType(RawImage));

    expect(tester.takeException(), isNull);
    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('PixaImage progress builder receives controller progress',
      (WidgetTester tester) async {
    await _configure('pixa-widget-progress-');
    final Completer<Uint8List> bytes = Completer<Uint8List>();
    final PixaController controller = PixaController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: PixaImage(
        controller: controller,
        request: PixaRequest(
          source: PixaSource.custom('progress', () => bytes.future),
          cachePolicy: const PixaCachePolicy.noStore(),
        ),
        progressBuilder: (BuildContext context, PixaProgress? progress) {
          return Text(
            progress?.fraction?.toStringAsFixed(2) ?? 'none',
            key: const Key('progress'),
          );
        },
      ),
    ));
    await tester.pump();

    controller.setState(const PixaLoading(
      progress: PixaProgress(
        requestId: 7,
        stage: PixaStage.fetch,
        receivedBytes: 1,
        expectedBytes: 4,
      ),
    ));
    await tester.pump();

    expect(find.text('0.25'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('PixaImage renders progressive preview from load progress',
      (WidgetTester tester) async {
    await _configure('pixa-widget-progressive-preview-');
    final Completer<Uint8List> bytes = Completer<Uint8List>();
    final PixaController controller = PixaController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: PixaImage(
        controller: controller,
        request: PixaRequest(
          source: PixaSource.custom('progressive-preview', () => bytes.future),
          cachePolicy: const PixaCachePolicy.noStore(),
        ),
        placeholder: const PixaPlaceholder.widget(
          SizedBox(key: Key('placeholder')),
        ),
      ),
    ));
    await tester.pump();

    controller.setState(PixaLoading(
      progress: PixaProgress(
        requestId: 8,
        stage: PixaStage.fetch,
        receivedBytes: 24,
        expectedBytes: 48,
        progressivePreview: PixaProgressivePreview(
          bytes: _progressiveJpegWithScan(),
          mimeType: 'image/jpeg',
          sequence: 1,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('placeholder')), findsNothing);
    expect(
      find.byWidgetPredicate(
        (Widget widget) => widget is Image && widget.image is MemoryImage,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('PixaImage error builder retry reloads the provider generation',
      (WidgetTester tester) async {
    await _configure('pixa-widget-retry-');
    const PixaTargetSize layoutTarget = PixaTargetSize(width: 1, height: 1);
    final PixaController controller = PixaController();
    addTearDown(controller.dispose);
    final ui.Image retryImage =
        await tester.runAsync(() => createTestImage(width: 1, height: 1)) ??
            (throw StateError('Failed to create decoded retry image.'));
    addTearDown(retryImage.dispose);
    var attempts = 0;
    late final PixaRequest request;
    request = PixaRequest(
      source: PixaSource.custom('retry', () async {
        attempts += 1;
        throw StateError('transient failure');
      }),
      cachePolicy: const PixaCachePolicy.noStore(),
    );
    controller.addListener(() {
      if (controller.generation == 1) {
        _seedDecodedCacheSync(
          request.copyWith(targetSize: layoutTarget),
          generation: controller.generation,
          image: retryImage,
        );
      }
    });

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 1),
        child: PixaImage(
          controller: controller,
          width: 1,
          height: 1,
          request: request,
          errorBuilder:
              (BuildContext context, PixaFailure failure, VoidCallback retry) {
            return TextButton(
              key: const Key('retry'),
              onPressed: retry,
              child: const Text('retry'),
            );
          },
        ),
      ),
    ));
    await tester.runAsync(_allowAsyncWork);
    await tester.pump();

    expect(find.byKey(const Key('retry')), findsOneWidget);
    expect(attempts, 1);

    await tester.tap(find.byKey(const Key('retry')));
    await tester.pump();
    await _pumpUntil(tester, find.byType(RawImage));

    expect(tester.takeException(), isNull);
    expect(find.byType(RawImage), findsOneWidget);
    expect(controller.generation, 1);
  });

  testWidgets('PixaImage detaches external controller on dispose',
      (WidgetTester tester) async {
    await _configure('pixa-widget-dispose-');
    final PixaController controller = PixaController();
    addTearDown(controller.dispose);
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('dispose', () async {
        throw StateError('decoded cache should satisfy this widget test');
      }),
      cachePolicy: const PixaCachePolicy.noStore(),
    );
    await _seedDecodedCache(tester, request);

    await tester.pumpWidget(MaterialApp(
      home: PixaImage(
        controller: controller,
        request: request,
      ),
    ));
    await tester.pump();

    expect(controller.isAttached, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(controller.isAttached, isFalse);
  });

  testWidgets('PixaImage updates controller visibility when scrolled offscreen',
      (WidgetTester tester) async {
    await _configure('pixa-widget-scroll-');
    final ScrollController scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    final PixaController controller = PixaController();
    addTearDown(controller.dispose);
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('scroll', () async {
        throw StateError('decoded cache should satisfy this widget test');
      }),
      cachePolicy: const PixaCachePolicy.noStore(),
    );
    await _seedDecodedCache(tester, request);

    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        height: 100,
        child: SingleChildScrollView(
          controller: scrollController,
          child: Column(
            children: <Widget>[
              SizedBox(
                height: 60,
                child: PixaImage(
                  controller: controller,
                  request: request,
                ),
              ),
              const SizedBox(height: 600),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(controller.isVisible, isTrue);

    scrollController.jumpTo(200);
    await tester.pump();
    await tester.pump();

    expect(controller.isVisible, isFalse);

    scrollController.jumpTo(0);
    await tester.pump();
    await tester.pump();

    expect(controller.isVisible, isTrue);
  });

  testWidgets(
      'PixaImage owned controller does not rebuild on scroll visibility',
      (WidgetTester tester) async {
    await _configure('pixa-widget-owned-scroll-');
    final ScrollController scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    final Completer<Uint8List> bytes = Completer<Uint8List>();
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('owned-scroll', () => bytes.future),
      cachePolicy: const PixaCachePolicy.noStore(),
    );
    var placeholderBuilds = 0;

    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        height: 100,
        child: SingleChildScrollView(
          controller: scrollController,
          child: Column(
            children: <Widget>[
              SizedBox(
                height: 60,
                child: PixaImage(
                  request: request,
                  placeholder: PixaPlaceholder.widget(
                    _BuildCounter(
                      onBuild: () => placeholderBuilds++,
                      child: const SizedBox(key: Key('owned-placeholder')),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 600),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
    final int initialBuilds = placeholderBuilds;

    scrollController.jumpTo(200);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('owned-placeholder')), findsOneWidget);
    expect(placeholderBuilds, initialBuilds);
  });

  testWidgets('PixaImage forwards gapless playback to Flutter Image',
      (WidgetTester tester) async {
    await _configure('pixa-widget-gapless-');
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('gapless', () async {
        throw StateError('decoded cache should satisfy this widget test');
      }),
      cachePolicy: const PixaCachePolicy.noStore(),
    );
    await _seedDecodedCache(tester, request);

    await tester.pumpWidget(MaterialApp(
      home: PixaImage(
        gaplessPlayback: true,
        request: request,
      ),
    ));
    await tester.pump();

    final Image image = tester.widget<Image>(find.byType(Image).first);
    expect(image.gaplessPlayback, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('PixaImage derives target size from layout and DPR',
      (WidgetTester tester) async {
    await _configure('pixa-widget-layout-target-');
    final Completer<Uint8List> bytes = Completer<Uint8List>();
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('layout-target', () => bytes.future),
      cachePolicy: const PixaCachePolicy.noStore(),
    );

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 2),
        child: Center(
          child: SizedBox(
            width: 80,
            height: 40,
            child: PixaImage(request: request),
          ),
        ),
      ),
    ));
    await tester.pump();

    final Image image = tester.widget<Image>(find.byType(Image).first);
    final PixaProvider provider = image.image as PixaProvider;
    expect(provider.request.targetSize,
        const PixaTargetSize(width: 160, height: 80));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('PixaImage preserves explicit request target size',
      (WidgetTester tester) async {
    await _configure('pixa-widget-explicit-target-');
    final Completer<Uint8List> bytes = Completer<Uint8List>();
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('explicit-target', () => bytes.future),
      targetSize: const PixaTargetSize(width: 500, height: 300),
      cachePolicy: const PixaCachePolicy.noStore(),
    );

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 3),
        child: Center(
          child: SizedBox(
            width: 80,
            height: 40,
            child: PixaImage(request: request),
          ),
        ),
      ),
    ));
    await tester.pump();

    final Image image = tester.widget<Image>(find.byType(Image).first);
    final PixaProvider provider = image.image as PixaProvider;
    expect(provider.request.targetSize,
        const PixaTargetSize(width: 500, height: 300));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('PixaImage skips layout probing for explicit target size',
      (WidgetTester tester) async {
    await _configure('pixa-widget-explicit-target-layout-');
    final Completer<Uint8List> bytes = Completer<Uint8List>();
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('explicit-target-layout', () => bytes.future),
      targetSize: const PixaTargetSize(width: 320, height: 180),
      cachePolicy: const PixaCachePolicy.noStore(),
    );

    await tester.pumpWidget(MaterialApp(
      home: PixaImage(
        request: request,
        placeholder: const PixaPlaceholder.widget(
          SizedBox(key: Key('explicit-target-placeholder')),
        ),
      ),
    ));
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(PixaImage),
        matching: find.byType(LayoutBuilder),
      ),
      findsNothing,
    );
    expect(
        find.byKey(const Key('explicit-target-placeholder')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

Future<void> _configure(String prefix) async {
  final ImageCache imageCache = PaintingBinding.instance.imageCache;
  imageCache.clear();
  imageCache.clearLiveImages();
  addTearDown(() {
    imageCache.clear();
    imageCache.clearLiveImages();
  });
  final Directory cacheRoot = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() => cacheRoot.delete(recursive: true));
  await Pixa.configure(PixaConfig(cacheRootPath: cacheRoot.path));
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 20,
}) async {
  for (var attempt = 0; attempt < maxPumps; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
}

Future<void> _allowAsyncWork() {
  return Future<void>.delayed(const Duration(milliseconds: 100));
}

Future<void> _seedDecodedCache(
  WidgetTester tester,
  PixaRequest request, {
  int generation = 0,
}) async {
  final ui.Image image =
      await tester.runAsync(() => createTestImage(width: 1, height: 1)) ??
          (throw StateError('Failed to create decoded test image.'));
  addTearDown(image.dispose);
  _seedDecodedCacheSync(request, generation: generation, image: image);
}

void _seedDecodedCacheSync(
  PixaRequest request, {
  int generation = 0,
  required ui.Image image,
}) {
  PaintingBinding.instance.imageCache.putIfAbsent(
    PixaProvider(request: request, generation: generation),
    () => OneFrameImageStreamCompleter(
      Future<ImageInfo>.value(ImageInfo(image: image.clone())),
    ),
  );
}

final class _BuildCounter extends StatelessWidget {
  const _BuildCounter({required this.onBuild, required this.child});

  final VoidCallback onBuild;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return child;
  }
}

Uint8List _progressiveJpegWithScan() {
  return base64Decode(
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQO'
    'DwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcH'
    'BwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgo'
    'KCgoKCgoKCgoKCgoKCj/wgARCAACAAIDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAA'
    'AAAAAAAAAAb/xAAVAQEBAAAAAAAAAAAAAAAAAAAFBv/aAAwDAQACEAMQAAABrBDl'
    'f//EABcQAAMBAAAAAAAAAAAAAAAAAAECBAP/2gAIAQEAAQUCgzQw/wD/xAAXEQAD'
    'AQAAAAAAAAAAAAAAAAAAAQMy/9oACAEDAQE/Aa7Z/8QAGBEAAgMAAAAAAAAAAAAA'
    'AAAAAAIDM3H/2gAIAQIBAT8BntbT/8QAGhAAAgIDAAAAAAAAAAAAAAAAAQIABBNB'
    'Yf/aAAgBAQAGPwKsSik411yf/8QAFhABAQEAAAAAAAAAAAAAAAAAASEA/9oACAE'
    'BAAE/IWZBlRY3/9oADAMBAAIAAwAAABAL/8QAFxEAAwEAAAAAAAAAAAAAAAAAAA'
    'Ghsf/aAAgBAwEBPxCl6f/EABcRAAMBAAAAAAAAAAAAAAAAAAABobH/2gAIAQIBA'
    'T8Qtaz/xAAXEAEBAQEAAAAAAAAAAAAAAAABEQAh/9oACAEBAAE/EHqSlKbKzrv'
    '/2Q==',
  );
}
