import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/src/pipeline.dart';

void main() {
  test('encoded prefetch target forces disk-only cache policy', () {
    final PixaRequest request = PixaRequest.network(
      'https://images.example.test/a.jpg',
      cachePolicy: const PixaCachePolicy.noStore(),
    );

    final PixaRequest prefetch = pixaEncodedPrefetchRequest(
      request,
      PixaPrefetchTarget.diskOnly,
    );

    expect(prefetch.priority, PixaPriority.low);
    expect(prefetch.cachePolicy.mode, PixaCacheMode.diskOnly);
    expect(prefetch.cachePolicy.maxAge, request.cachePolicy.maxAge);
  });

  test('encoded prefetch target forces memory-only cache policy', () {
    final PixaRequest request = PixaRequest.network(
      'https://images.example.test/a.jpg',
      cachePolicy: const PixaCachePolicy.noStore(),
    );

    final PixaRequest prefetch = pixaEncodedPrefetchRequest(
      request,
      PixaPrefetchTarget.encodedMemory,
    );

    expect(prefetch.priority, PixaPriority.low);
    expect(prefetch.cachePolicy.mode, PixaCacheMode.memoryOnly);
  });

  test('decoded prefetch target is rejected by encoded pipeline helper', () {
    final PixaRequest request = PixaRequest.network(
      'https://images.example.test/a.jpg',
    );

    expect(
      () => pixaEncodedPrefetchRequest(
        request,
        PixaPrefetchTarget.decodedPrewarm,
      ),
      throwsArgumentError,
    );
  });

  test('decoded prewarm target avoids encoded memory writes', () {
    final PixaRequest request = PixaRequest.network(
      'https://images.example.test/a.jpg',
    );

    final PixaRequest prewarm = pixaDecodedPrewarmRequest(request);

    expect(prewarm.priority, PixaPriority.low);
    expect(prewarm.cachePolicy.mode, PixaCacheMode.diskOnly);
  });

  test('decoded prewarm preserves explicit no-store policy', () {
    final PixaRequest request = PixaRequest.network(
      'https://images.example.test/a.jpg',
      cachePolicy: const PixaCachePolicy.noStore(),
    );

    final PixaRequest prewarm = pixaDecodedPrewarmRequest(request);

    expect(prewarm.priority, PixaPriority.low);
    expect(prewarm.cachePolicy.mode, PixaCacheMode.noStore);
  });

  test('decoded prewarm preserves visible decoded identity inputs', () {
    final PixaRequest request = PixaRequest.network(
      'https://images.example.test/a.jpg',
      targetSize: const PixaTargetSize(width: 96, height: 96),
      decoderOptions: const <String, Object?>{'colorSpace': 'srgb'},
    );

    final PixaRequest prewarm = pixaDecodedPrewarmRequest(request);

    expect(prewarm.source, same(request.source));
    expect(prewarm.targetSize, request.targetSize);
    expect(prewarm.scale, request.scale);
    expect(prewarm.fit, request.fit);
    expect(prewarm.processors, request.processors);
    expect(prewarm.decoderOptions, request.decoderOptions);
  });

  test('decoded prefetch requires a BuildContext', () {
    final PixaRequest request = PixaRequest.network(
      'https://images.example.test/a.jpg',
    );

    expect(
      Pixa.prefetch(request, target: PixaPrefetchTarget.decodedPrewarm),
      throwsArgumentError,
    );
  });
}
