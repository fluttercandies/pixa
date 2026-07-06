import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

void main() {
  test('PixaProcessors builds stable runtime processor descriptors', () {
    expect(
      PixaProcessors.resize(
        width: 64,
        height: 48,
        mode: PixaResizeMode.exact,
        filter: PixaResizeFilter.nearest,
      ),
      'resize(width=64,height=48,mode=exact,filter=nearest)',
    );
    expect(
      PixaProcessors.resize(width: 64),
      'resize(width=64,mode=fit,filter=lanczos3)',
    );
    expect(
      PixaProcessors.resizeExact(32, 24, filter: PixaResizeFilter.triangle),
      'resizeExact(width=32,height=24,filter=triangle)',
    );
    expect(
      PixaProcessors.crop(x: 1, y: 2, width: 3, height: 4),
      'crop(x=1,y=2,width=3,height=4)',
    );
    expect(PixaProcessors.rotate(90), 'rotate(degrees=90)');
    expect(PixaProcessors.blur(2.5), 'blur(sigma=2.5)');
    expect(PixaProcessors.fastBlur(1.5), 'fastBlur(sigma=1.5)');
    expect(
      PixaProcessors.tileCropResize(
        x: 1,
        y: 2,
        width: 100,
        height: 80,
        decodedWidth: 50,
        decodedHeight: 40,
        sampleSize: 2,
        filter: PixaResizeFilter.catmullRom,
      ),
      'tile(x=1,y=2,width=100,height=80,decodedWidth=50,decodedHeight=40,sampleSize=2,filter=catmullrom)',
    );
    expect(PixaProcessors.flipHorizontal(), 'flipHorizontal()');
    expect(PixaProcessors.flipVertical(), 'flipVertical()');
    expect(PixaProcessors.grayscale(), 'grayscale()');
    expect(PixaProcessors.invert(), 'invert()');
    expect(PixaProcessors.brighten(32), 'brighten(value=32)');
    expect(PixaProcessors.contrast(-12.5), 'contrast(value=-12.5)');
    expect(PixaProcessors.hueRotate(120), 'hueRotate(degrees=120)');
    expect(
      PixaProcessors.unsharpen(sigma: 1.25, threshold: 3),
      'unsharpen(sigma=1.25,threshold=3)',
    );
  });

  test('PixaProcessors validates bounded runtime processor arguments', () {
    expect(PixaProcessors.resize, throwsArgumentError);
    expect(() => PixaProcessors.resize(width: 0), throwsRangeError);
    expect(
      () => PixaProcessors.crop(x: -1, y: 0, width: 1, height: 1),
      throwsRangeError,
    );
    expect(
      () => PixaProcessors.crop(x: 0, y: 0, width: 0, height: 1),
      throwsRangeError,
    );
    expect(() => PixaProcessors.rotate(45), throwsArgumentError);
    expect(() => PixaProcessors.blur(double.nan), throwsRangeError);
    expect(() => PixaProcessors.fastBlur(-0.1), throwsRangeError);
    expect(() => PixaProcessors.fastBlur(double.nan), throwsRangeError);
    expect(
      () => PixaProcessors.tileCropResize(
        x: 0,
        y: 0,
        width: 1,
        height: 1,
        decodedWidth: 1,
        decodedHeight: 1,
        sampleSize: 0,
      ),
      throwsRangeError,
    );
    expect(() => PixaProcessors.brighten(256), throwsRangeError);
    expect(() => PixaProcessors.brighten(-256), throwsRangeError);
    expect(() => PixaProcessors.contrast(256), throwsRangeError);
    expect(() => PixaProcessors.hueRotate(361), throwsRangeError);
    expect(() => PixaProcessors.hueRotate(-361), throwsRangeError);
    expect(
      () => PixaProcessors.unsharpen(sigma: double.infinity, threshold: 1),
      throwsRangeError,
    );
    expect(
      () => PixaProcessors.unsharpen(sigma: 1, threshold: -1),
      throwsRangeError,
    );
    expect(
      () => PixaProcessors.unsharpen(sigma: 1, threshold: 256),
      throwsRangeError,
    );
  });
}
