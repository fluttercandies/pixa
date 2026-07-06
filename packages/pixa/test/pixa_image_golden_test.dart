import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PixaImage error recovery surface remains stable',
      (WidgetTester tester) async {
    await _configure('pixa-golden-error-');
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('golden-error', () async {
        throw StateError('golden source failure');
      }),
      cachePolicy: const PixaCachePolicy.noStore(),
    );

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Center(
        child: RepaintBoundary(
          key: const Key('pixa-golden-target'),
          child: SizedBox(
            width: 180,
            height: 120,
            child: PixaImage(
              request: request,
              errorBuilder: (BuildContext context, PixaFailure failure,
                  VoidCallback retry) {
                return const _DeterministicErrorSurface();
              },
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();

    await expectLater(
      find.byKey(const Key('pixa-golden-target')),
      matchesGoldenFile('goldens/pixa_image_error_surface.png'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

class _DeterministicErrorSurface extends StatelessWidget {
  const _DeterministicErrorSurface();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFFFFF5F2),
      child: CustomPaint(painter: _ErrorSurfacePainter()),
    );
  }
}

class _ErrorSurfacePainter extends CustomPainter {
  const _ErrorSurfacePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint stroke = Paint()
      ..color = const Color(0xFFD85D4A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final Paint fill = Paint()
      ..color = const Color(0xFFFFD6CD)
      ..style = PaintingStyle.fill;
    final Rect badge = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: 52,
      height: 52,
    );
    canvas.drawOval(badge, fill);
    canvas.drawOval(badge, stroke);
    canvas.drawLine(
      badge.center + const Offset(-12, -12),
      badge.center + const Offset(12, 12),
      stroke,
    );
    canvas.drawLine(
      badge.center + const Offset(12, -12),
      badge.center + const Offset(-12, 12),
      stroke,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
