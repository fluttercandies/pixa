import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

void main() {
  test('PixaController reassemble bumps generation only while attached', () {
    final PixaController controller = PixaController();

    controller.reassemble();
    expect(controller.generation, 0);

    controller.attach();
    controller.reassemble();
    expect(controller.generation, 1);
    expect(controller.state, isA<PixaLoading>());

    controller.detach();
    controller.reassemble();
    expect(controller.generation, 1);

    controller.dispose();
  });

  test('PixaController ignores lifecycle mutations after dispose', () {
    final PixaController controller = PixaController()
      ..attach()
      ..visible();
    controller.dispose();

    expect(controller.reload, returnsNormally);
    expect(controller.retry, returnsNormally);
    expect(controller.cancel, returnsNormally);
    expect(controller.attach, returnsNormally);
    expect(controller.detach, returnsNormally);
    expect(controller.visible, returnsNormally);
    expect(controller.invisible, returnsNormally);
    expect(controller.pause, returnsNormally);
    expect(controller.resume, returnsNormally);
    expect(controller.reassemble, returnsNormally);
    expect(controller.isAttached, isFalse);
    expect(controller.isVisible, isFalse);
    expect(controller.generation, 0);
  });

  test('PixaController deduplicates unchanged loading state', () {
    final PixaController controller = PixaController();
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() {
      notifications += 1;
    });
    const PixaProgress progress = PixaProgress(
      requestId: 1,
      stage: PixaStage.fetch,
      receivedBytes: 1,
      expectedBytes: 2,
    );

    controller.setState(const PixaLoading());
    controller.setState(const PixaLoading());
    controller.setState(const PixaLoading(progress: progress));
    controller.setState(const PixaLoading(progress: progress));
    controller.setState(
      const PixaLoading(
        progress: PixaProgress(
          requestId: 1,
          stage: PixaStage.fetch,
          receivedBytes: 2,
          expectedBytes: 2,
        ),
      ),
    );

    expect(notifications, 3);
  });
}
