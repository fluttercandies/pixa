import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

void main() {
  test('PixaProcessors builds stable runtime processor descriptors', () {
    expect(PixaProcessors.flipHorizontal(), 'flipHorizontal()');
    expect(PixaProcessors.flipVertical(), 'flipVertical()');
    expect(PixaProcessors.grayscale(), 'grayscale()');
    expect(PixaProcessors.invert(), 'invert()');
    expect(PixaProcessors.brighten(32), 'brighten(value=32)');
    expect(PixaProcessors.contrast(-12.5), 'contrast(value=-12.5)');
    expect(PixaProcessors.hueRotate(120), 'hueRotate(degrees=120)');
  });

  test('PixaProcessors validates bounded runtime processor arguments', () {
    expect(() => PixaProcessors.brighten(256), throwsRangeError);
    expect(() => PixaProcessors.brighten(-256), throwsRangeError);
    expect(() => PixaProcessors.contrast(256), throwsRangeError);
    expect(() => PixaProcessors.hueRotate(361), throwsRangeError);
    expect(() => PixaProcessors.hueRotate(-361), throwsRangeError);
  });
}
