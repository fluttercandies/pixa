import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa_gallery/main.dart';

void main() {
  test('gallery app entry widget is constructible', () {
    expect(const PixaGalleryApp(), isA<PixaGalleryApp>());
  });

  testWidgets('scenario control bar wraps compact mobile preview controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 131,
            child: PixaScenarioControlBar(
              children: List<Widget>.generate(
                4,
                (int index) => const SizedBox.square(dimension: 40),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(PixaScenarioControlBar)).height,
      greaterThan(40),
    );
  });
}
