import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

void main() {
  test('PixaSourceSet selects the smallest MIME-compatible candidate', () {
    final PixaSourceSet set = PixaSourceSet(<PixaSourceSetCandidate>[
      PixaSourceSetCandidate.network(
        'https://cdn.example.test/photo-400.jpg',
        width: 400,
        mimeType: 'image/jpeg',
      ),
      PixaSourceSetCandidate.network(
        'https://cdn.example.test/photo-800.webp',
        width: 800,
        mimeType: 'image/webp',
      ),
      PixaSourceSetCandidate.network(
        'https://cdn.example.test/photo-1200.webp',
        width: 1200,
        mimeType: 'image/webp',
      ),
    ]);

    final PixaSourceSetCandidate selected = set.select(
      logicalWidth: 300,
      devicePixelRatio: 2,
      acceptedMimeTypes: const <String>['image/webp', 'image/jpeg'],
    );

    expect(selected.width, 800);
    expect(
      (selected.source as PixaNetworkSource).uri.toString(),
      'https://cdn.example.test/photo-800.webp',
    );
  });

  test('PixaSourceSet creates target-sized requests from selected source', () {
    final PixaSourceSet set = PixaSourceSet(<PixaSourceSetCandidate>[
      PixaSourceSetCandidate.network(
        'https://cdn.example.test/photo-400.jpg',
        width: 400,
      ),
      PixaSourceSetCandidate.network(
        'https://cdn.example.test/photo-900.jpg',
        width: 900,
      ),
    ]);

    final PixaRequest request = set.selectRequest(
      logicalWidth: 220,
      logicalHeight: 120,
      devicePixelRatio: 2,
      baseRequest: PixaRequest.network(
        'https://cdn.example.test/fallback.jpg',
        cachePolicy: const PixaCachePolicy(mode: PixaCacheMode.memoryOnly),
        priority: PixaPriority.high,
      ),
    );

    expect(
      (request.source as PixaNetworkSource).uri.toString(),
      'https://cdn.example.test/photo-900.jpg',
    );
    expect(request.targetSize, const PixaTargetSize(width: 440, height: 240));
    expect(
      request.cachePolicy,
      const PixaCachePolicy(mode: PixaCacheMode.memoryOnly),
    );
    expect(request.priority, PixaPriority.high);
  });
}
