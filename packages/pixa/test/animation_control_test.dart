import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/src/display_decoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PixaAnimationController exposes explicit playback states', () {
    final PixaAnimationController controller = PixaAnimationController();
    addTearDown(controller.dispose);
    final List<PixaAnimationPlaybackState> states =
        <PixaAnimationPlaybackState>[];
    controller.addListener(() => states.add(controller.state));

    expect(controller.state, PixaAnimationPlaybackState.playing);
    controller.pause();
    controller.resume();
    controller.stop();
    controller.play();

    expect(states, <PixaAnimationPlaybackState>[
      PixaAnimationPlaybackState.paused,
      PixaAnimationPlaybackState.playing,
      PixaAnimationPlaybackState.stopped,
      PixaAnimationPlaybackState.playing,
    ]);
  });

  testWidgets('controlled animation completer pauses frame scheduling', (
    WidgetTester tester,
  ) async {
    final PixaAnimationController controller = PixaAnimationController();
    addTearDown(controller.dispose);
    final List<ui.Image> sourceFrames =
        await tester.runAsync(
              () async => <ui.Image>[
                await _onePixelImage(1),
                await _onePixelImage(2),
              ],
            )
            as List<ui.Image>;
    addTearDown(() {
      for (final ui.Image image in sourceFrames) {
        image.dispose();
      }
    });
    final _FakeCodec codec = _FakeCodec(sourceFrames);
    final ImageStreamCompleter completer =
        PixaControlledAnimatedImageStreamCompleter(
          codec: SynchronousFuture<ui.Codec>(codec),
          scale: 1,
          debugLabel: 'controlled-animation-test',
          informationCollector: () => <DiagnosticsNode>[
            ErrorDescription('controlled animation test'),
          ],
          controller: controller,
          options: const PixaAnimationOptions(
            frameCachePolicy: PixaAnimationFrameCachePolicy.keepNextFrame,
            disposalPolicy: PixaAnimationDisposalPolicy.disposeDecodedFrames,
          ),
        );
    final List<int> frames = <int>[];
    final ImageStreamListener listener = ImageStreamListener((
      ImageInfo image,
      bool synchronousCall,
    ) {
      frames.add(codec.framesServed);
      image.dispose();
    });

    completer.addListener(listener);
    await _pumpUntil(tester, () => frames.isNotEmpty);
    expect(frames, <int>[1]);

    controller.pause();
    await tester.pump(const Duration(milliseconds: 200));
    expect(frames, <int>[1]);

    controller.resume();
    await _pumpUntil(tester, () => frames.length > 1);
    expect(frames.length, greaterThan(1));
    completer.removeListener(listener);
  });

  test('PixaProvider animation controllers isolate decoded stream keys', () {
    final PixaRequest request = PixaRequest(
      source: PixaSource.custom('animated-key', () async => _minimalGif()),
    );
    final PixaAnimationController firstController = PixaAnimationController();
    final PixaAnimationController secondController = PixaAnimationController();
    addTearDown(firstController.dispose);
    addTearDown(secondController.dispose);

    expect(
      PixaProvider(request: request, animationController: firstController),
      isNot(
        PixaProvider(request: request, animationController: secondController),
      ),
    );
    expect(PixaProvider(request: request), PixaProvider(request: request));
  });
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxPumps = 20,
}) async {
  for (var attempt = 0; attempt < maxPumps && !condition(); attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

final class _FakeCodec implements ui.Codec {
  _FakeCodec(this._images);

  final List<ui.Image> _images;
  int framesServed = 0;
  bool isDisposed = false;

  @override
  int get frameCount => 2;

  @override
  int get repetitionCount => -1;

  @override
  Future<ui.FrameInfo> getNextFrame() {
    framesServed += 1;
    return SynchronousFuture<ui.FrameInfo>(
      _FakeFrameInfo(_images[(framesServed - 1) % _images.length].clone()),
    );
  }

  @override
  void dispose() {
    isDisposed = true;
  }
}

final class _FakeFrameInfo implements ui.FrameInfo {
  _FakeFrameInfo(this.image);

  @override
  final ui.Image image;

  @override
  Duration get duration => const Duration(milliseconds: 40);
}

Future<ui.Image> _onePixelImage(int frame) async {
  final Uint8List bytes = Uint8List.fromList(<int>[
    frame.isOdd ? 0xff : 0x00,
    frame.isOdd ? 0x00 : 0xff,
    0x00,
    0xff,
  ]);
  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
    bytes,
  );
  final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: 1,
    height: 1,
    rowBytes: 4,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final ui.Codec codec = await descriptor.instantiateCodec();
  final ui.FrameInfo frameInfo = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frameInfo.image;
}

Uint8List _minimalGif() {
  return Uint8List.fromList(
    base64Decode('R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=='),
  );
}
