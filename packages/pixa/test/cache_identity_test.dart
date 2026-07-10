import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/src/cache_key.dart';
import 'package:pixa/src/runtime/runtime_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cache key canonical encoding separates ambiguous values and types', () {
    final List<(PixaCacheKey, PixaCacheKey)> formerlyColliding =
        <(PixaCacheKey, PixaCacheKey)>[
          (
            PixaCacheKey.fromParts(<Object?>['a\nb']),
            PixaCacheKey.fromParts(<Object?>['a', 'b']),
          ),
          (
            PixaCacheKey.fromParts(<Object?>[
              <Object?>['a,b'],
            ]),
            PixaCacheKey.fromParts(<Object?>[
              <Object?>['a', 'b'],
            ]),
          ),
          (
            PixaCacheKey.fromParts(<Object?>[
              <String, Object?>{'a': 'b&c=d'},
            ]),
            PixaCacheKey.fromParts(<Object?>[
              <String, Object?>{'a': 'b', 'c': 'd'},
            ]),
          ),
          (
            PixaCacheKey.fromParts(<Object?>[1]),
            PixaCacheKey.fromParts(<Object?>['1']),
          ),
        ];

    for (final (PixaCacheKey first, PixaCacheKey second) in formerlyColliding) {
      expect(first, isNot(second));
    }
  });

  test('cache key canonical encoding sorts maps by encoded keys', () {
    final PixaCacheKey first = PixaCacheKey.fromParts(<Object?>[
      <Object?, Object?>{'b': 2, 'a': 1},
    ]);
    final PixaCacheKey second = PixaCacheKey.fromParts(<Object?>[
      <Object?, Object?>{'a': 1, 'b': 2},
    ]);

    expect(first, second);
  });

  test('cache key rejects unsupported nondeterministic values', () {
    expect(
      () => PixaCacheKey.fromParts(<Object?>[
        <String>{'a', 'b'},
      ]),
      throwsA(
        isA<ArgumentError>().having(
          (ArgumentError error) => error.message,
          'message',
          contains('Set<String>'),
        ),
      ),
    );
  });

  test('runtime hash pair exposes the first 128 bits of SHA-256', () {
    final Uint8List bytes = Uint8List.fromList(utf8.encode('pixa'));
    final PixaRuntimeHashPair pair = PixaRuntimeBridge.cacheKeyHashPair(bytes);

    expect(PixaRuntimeBridge.uint64Hex(pair.primary), '164fb963c3f92416');
    expect(PixaRuntimeBridge.uint64Hex(pair.secondary), 'bf647e7f0875c5ab');
    expect(
      PixaRuntimeBridge.hashHex(bytes),
      '164fb963c3f92416bf647e7f0875c5ab',
    );
    expect(PixaCacheKey.fromParts(<Object?>['pixa']).value, hasLength(32));
  });

  test('header vary lookup is case-insensitive', () {
    final PixaRequest first = PixaRequest(
      source: PixaSource.network(Uri.parse('https://images.test/a.png')),
      headers: <String, String>{'X-Variant': 'one'},
      headersPolicy: PixaHeadersPolicy(varyHeaders: <String>{'x-variant'}),
    );
    final PixaRequest second = PixaRequest(
      source: PixaSource.network(Uri.parse('https://images.test/a.png')),
      headers: <String, String>{'X-Variant': 'two'},
      headersPolicy: PixaHeadersPolicy(varyHeaders: <String>{'X-VARIANT'}),
    );

    expect(first.cacheKey, isNot(second.cacheKey));
  });

  test(
    'URI userInfo is redacted and cryptographically partitions identity',
    () {
      final PixaRequest first = PixaRequest.network(
        'https://alice:alpha@images.test/a.png',
      );
      final PixaRequest second = PixaRequest.network(
        'https://alice:bravo@images.test/a.png',
      );

      expect(first.cacheKey, isNot(second.cacheKey));
      expect(first.source.safeLabel, isNot(contains('alice')));
      expect(first.source.safeLabel, isNot(contains('alpha')));
      expect(first.cacheKey.debugLabel, isNot(contains('alpha')));
      expect(first.source.cacheMaterial.toString(), isNot(contains('alpha')));
    },
  );

  test('custom asset bundle instances have process-scoped identities', () {
    final AssetBundle firstBundle = _TestAssetBundle();
    final AssetBundle secondBundle = _TestAssetBundle();

    final PixaRequest first = PixaRequest.asset(
      'images/a.png',
      bundle: firstBundle,
    );
    final PixaRequest sameBundle = PixaRequest.asset(
      'images/a.png',
      bundle: firstBundle,
    );
    final PixaRequest second = PixaRequest.asset(
      'images/a.png',
      bundle: secondBundle,
    );

    expect(first.cacheKey, sameBundle.cacheKey);
    expect(first.cacheKey, isNot(second.cacheKey));
  });
}

final class _TestAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData(0);
}
