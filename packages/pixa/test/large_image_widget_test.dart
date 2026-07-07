import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('large image double tap toggles focused zoom', (
    WidgetTester tester,
  ) async {
    await _configure('pixa-large-image-double-tap-');
    final Completer<Uint8List> pendingBytes = Completer<Uint8List>();
    final PixaLargeImageController controller = PixaLargeImageController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 1),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 500,
              height: 500,
              child: PixaLargeImage(
                request: PixaRequest(
                  source: PixaSource.custom(
                    'large-image-double-tap',
                    () => pendingBytes.future,
                  ),
                  cachePolicy: const PixaCachePolicy.noStore(),
                ),
                imageWidth: 1000,
                imageHeight: 1000,
                controller: controller,
                showOverview: false,
                prefetchTiles: false,
                evictDecodedTilesOnExit: false,
                doubleTapZoomDuration: Duration.zero,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.getSize(find.byType(PixaLargeImage)), const Size(500, 500));

    expect(controller.scale, closeTo(0.5, 0.0001));

    final Offset center = tester.getCenter(find.byType(PixaLargeImage));
    await _doubleTapAt(tester, center);

    expect(controller.scale, closeTo(1.0, 0.0001));

    await _doubleTapAt(tester, center);

    expect(controller.scale, closeTo(0.5, 0.0001));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('large image controller zoom clamps to image bounds', (
    WidgetTester tester,
  ) async {
    await _configure('pixa-large-image-controller-');
    final Completer<Uint8List> pendingBytes = Completer<Uint8List>();
    final PixaLargeImageController controller = PixaLargeImageController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 1),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 500,
              height: 500,
              child: PixaLargeImage(
                request: PixaRequest(
                  source: PixaSource.custom(
                    'large-image-controller',
                    () => pendingBytes.future,
                  ),
                  cachePolicy: const PixaCachePolicy.noStore(),
                ),
                imageWidth: 1000,
                imageHeight: 1000,
                controller: controller,
                showOverview: false,
                prefetchTiles: false,
                evictDecodedTilesOnExit: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    controller.zoomTo(4, focalPoint: const Offset(500, 500));
    await tester.pump();

    expect(controller.scale, closeTo(4.0, 0.0001));
    expect(controller.value.storage[12], greaterThanOrEqualTo(-3500.0001));
    expect(controller.value.storage[12], lessThanOrEqualTo(0.0001));
    expect(controller.value.storage[13], greaterThanOrEqualTo(-3500.0001));
    expect(controller.value.storage[13], lessThanOrEqualTo(0.0001));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('large image uses tile error builder for tile failures', (
    WidgetTester tester,
  ) async {
    await _configure('pixa-large-image-tile-error-');

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 1),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 256,
              height: 256,
              child: PixaLargeImage(
                request: PixaRequest(
                  source: PixaSource.custom(
                    'large-image-tile-error',
                    () => Future<Uint8List>.error(StateError('tile failed')),
                  ),
                  cachePolicy: const PixaCachePolicy.noStore(),
                ),
                imageWidth: 512,
                imageHeight: 512,
                tileMode: PixaLargeImageTileMode.always,
                tileSize: 512,
                showOverview: false,
                prefetchTiles: false,
                evictDecodedTilesOnExit: false,
                errorBuilder: (_, _, _) => const Text('overview-error'),
                tileErrorBuilder: (_, _, _) => const Text('tile-error'),
              ),
            ),
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.text('tile-error'));

    expect(find.text('tile-error'), findsWidgets);
    expect(find.text('overview-error'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('large image adaptive mode displays small images directly', (
    WidgetTester tester,
  ) async {
    await _configure('pixa-large-image-small-direct-');

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 1),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 256,
              height: 256,
              child: PixaLargeImage(
                request: PixaRequest(
                  source: PixaSource.custom(
                    'large-image-small-direct',
                    () => Future<Uint8List>.error(StateError('direct failed')),
                  ),
                  cachePolicy: const PixaCachePolicy.noStore(),
                ),
                imageWidth: 512,
                imageHeight: 512,
                showOverview: false,
                prefetchTiles: false,
                evictDecodedTilesOnExit: false,
                errorBuilder: (_, _, _) => const Text('direct-error'),
                tileErrorBuilder: (_, _, _) => const Text('tile-error'),
              ),
            ),
          ),
        ),
      ),
    );

    await _pumpUntilFound(tester, find.text('direct-error'));

    expect(find.text('direct-error'), findsOneWidget);
    expect(find.text('tile-error'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets(
    'large image never tile mode displays oversized images directly',
    (WidgetTester tester) async {
      await _configure('pixa-large-image-never-direct-');

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 1),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 256,
                height: 256,
                child: PixaLargeImage(
                  request: PixaRequest(
                    source: PixaSource.custom(
                      'large-image-never-direct',
                      () =>
                          Future<Uint8List>.error(StateError('direct failed')),
                    ),
                    cachePolicy: const PixaCachePolicy.noStore(),
                  ),
                  imageWidth: 6000,
                  imageHeight: 4000,
                  tileMode: PixaLargeImageTileMode.never,
                  showOverview: false,
                  prefetchTiles: false,
                  evictDecodedTilesOnExit: false,
                  errorBuilder: (_, _, _) => const Text('direct-error'),
                  tileErrorBuilder: (_, _, _) => const Text('tile-error'),
                ),
              ),
            ),
          ),
        ),
      );

      await _pumpUntilFound(tester, find.text('direct-error'));

      expect(find.text('direct-error'), findsOneWidget);
      expect(find.text('tile-error'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    },
  );
}

Future<void> _doubleTapAt(WidgetTester tester, Offset position) async {
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(position);
  await tester.pump();
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 20; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
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
