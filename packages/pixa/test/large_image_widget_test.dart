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
}

Future<void> _doubleTapAt(WidgetTester tester, Offset position) async {
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(position);
  await tester.pump();
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
