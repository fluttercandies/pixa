import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

void main() {
  test(
    'PixaCacheWarmupManifest records per-entry success and failure',
    () async {
      final PixaCacheWarmupManifest manifest = PixaCacheWarmupManifest(
        <PixaCacheWarmupEntry>[
          PixaCacheWarmupEntry(
            id: 'hero',
            request: PixaRequest.network('https://cdn.example.test/hero.jpg'),
            target: PixaPrefetchTarget.diskOnly,
          ),
          PixaCacheWarmupEntry(
            id: 'avatar',
            request: PixaRequest.network('https://cdn.example.test/avatar.jpg'),
            target: PixaPrefetchTarget.encodedMemory,
          ),
        ],
      );
      final List<String> visited = <String>[];

      final PixaCacheWarmupReport report = await manifest.run((
        PixaCacheWarmupEntry entry,
      ) async {
        visited.add(entry.id);
        if (entry.id == 'avatar') {
          throw StateError('network unavailable');
        }
      });

      expect(visited, <String>['hero', 'avatar']);
      expect(report.totalCount, 2);
      expect(report.successCount, 1);
      expect(report.failureCount, 1);
      expect(report.succeededIds, <String>['hero']);
      expect(report.failures.single.id, 'avatar');
      expect(report.stoppedAfterFailure, isFalse);
    },
  );

  test('PixaCacheWarmupManifest can stop after first failure', () async {
    final PixaCacheWarmupManifest manifest =
        PixaCacheWarmupManifest(<PixaCacheWarmupEntry>[
          PixaCacheWarmupEntry(
            id: 'first',
            request: PixaRequest.network('https://cdn.example.test/first.jpg'),
          ),
          PixaCacheWarmupEntry(
            id: 'second',
            request: PixaRequest.network('https://cdn.example.test/second.jpg'),
          ),
        ]);
    final List<String> visited = <String>[];

    final PixaCacheWarmupReport report = await manifest.run((
      PixaCacheWarmupEntry entry,
    ) async {
      visited.add(entry.id);
      throw StateError('stop');
    }, continueOnError: false);

    expect(visited, <String>['first']);
    expect(report.successCount, 0);
    expect(report.failureCount, 1);
    expect(report.stoppedAfterFailure, isTrue);
  });
}
