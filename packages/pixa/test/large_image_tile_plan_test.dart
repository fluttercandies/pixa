import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

void main() {
  test('planner returns only visible tiles at full resolution', () {
    const PixaLargeImageTilePlanner planner = PixaLargeImageTilePlanner(
      imageSize: PixaLargeImageSize(width: 2048, height: 1024),
      tileSize: 256,
      cacheExtentScreens: 0,
      maxVisibleTiles: 16,
    );

    final PixaLargeImageTilePlan plan = planner.plan(
      transform: Matrix4.identity(),
      viewportSize: const Size(512, 512),
      devicePixelRatio: 1,
    );

    expect(plan.sampleSize, 1);
    expect(plan.visibleRect, const Rect.fromLTWH(0, 0, 512, 512));
    expect(plan.visibleTiles, hasLength(4));
    expect(plan.prefetchTiles, isEmpty);
    expect(plan.tiles, hasLength(4));
    expect(
      plan.tiles.map((PixaLargeImageTile tile) => tile.sourceRect).toSet(),
      <Rect>{
        const Rect.fromLTWH(0, 0, 256, 256),
        const Rect.fromLTWH(256, 0, 256, 256),
        const Rect.fromLTWH(0, 256, 256, 256),
        const Rect.fromLTWH(256, 256, 256, 256),
      },
    );
  });

  test('planner chooses sampled tiles for zoomed-out large images', () {
    const PixaLargeImageTilePlanner planner = PixaLargeImageTilePlanner(
      imageSize: PixaLargeImageSize(width: 20000, height: 10000),
      tileSize: 512,
      cacheExtentScreens: 0,
      maxVisibleTiles: 24,
    );

    final PixaLargeImageTilePlan plan = planner.plan(
      transform: Matrix4.identity()..scaleByDouble(0.05, 0.05, 1, 1),
      viewportSize: const Size(1000, 500),
      devicePixelRatio: 2,
    );

    expect(plan.sampleSize, 8);
    expect(plan.visibleTiles.length, lessThanOrEqualTo(24));
    expect(plan.prefetchTiles, isEmpty);
    expect(
      plan.tiles.every(
        (PixaLargeImageTile tile) =>
            tile.decodedWidth <= 512 && tile.decodedHeight <= 512,
      ),
      isTrue,
    );
  });

  test('tile request shares encoded key and creates a final variant key', () {
    const PixaLargeImageTilePlanner planner = PixaLargeImageTilePlanner(
      imageSize: PixaLargeImageSize(width: 1024, height: 1024),
      tileSize: 512,
      cacheExtentScreens: 0,
      maxVisibleTiles: 4,
    );
    final PixaRequest base = PixaRequest.network(
      'https://example.com/large.jpg',
    );
    final PixaLargeImageTile tile = planner
        .plan(
          transform: Matrix4.identity(),
          viewportSize: const Size(512, 512),
          devicePixelRatio: 1,
        )
        .tiles
        .single;

    final PixaRequest tileRequest = tile.requestFor(base);

    expect(tileRequest.encodedCacheKey, base.encodedCacheKey);
    expect(tileRequest.cacheKey, isNot(base.cacheKey));
    expect(tileRequest.processors, <String>[
      'tile(x=0,y=0,width=512,height=512,'
          'decodedWidth=512,decodedHeight=512,filter=triangle)',
    ]);
    expect(
      tileRequest.targetSize,
      const PixaTargetSize(width: 512, height: 512),
    );
  });

  test('planner separates visible tiles from near-viewport prefetch tiles', () {
    const PixaLargeImageTilePlanner planner = PixaLargeImageTilePlanner(
      imageSize: PixaLargeImageSize(width: 1024, height: 1024),
      tileSize: 256,
      cacheExtentScreens: 1,
      maxVisibleTiles: 16,
    );

    final PixaLargeImageTilePlan plan = planner.plan(
      transform: Matrix4.identity(),
      viewportSize: const Size(256, 256),
      devicePixelRatio: 1,
    );

    expect(plan.visibleTiles, hasLength(1));
    expect(plan.prefetchTiles, isNotEmpty);
    expect(
      plan.prefetchTiles
          .map((PixaLargeImageTile tile) => tile.key)
          .contains(plan.visibleTiles.single.key),
      isFalse,
    );
    expect(
      plan.tileCount,
      plan.visibleTiles.length + plan.prefetchTiles.length,
    );
  });
}
