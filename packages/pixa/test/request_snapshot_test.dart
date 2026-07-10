import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/src/runtime/runtime_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('request snapshots caller collections and nested supported values', () {
    final Map<String, String> headers = <String, String>{'X-Variant': 'one'};
    final List<PixaSource> sources = <PixaSource>[
      PixaSource.network(Uri.parse('https://images.test/fallback.png')),
    ];
    final List<String> processors = <String>['resize(width=10)'];
    final Set<String> varyHeaders = <String>{'X-Variant'};
    final List<Object?> decoderNested = <Object?>[
      1,
      <String, Object?>{'mode': 'fast'},
    ];
    final Map<String, Object?> decoderOptions = <String, Object?>{
      'mimeType': 'image/png',
      'nested': decoderNested,
    };
    final List<Object?> metadataTags = <Object?>['original'];
    final Map<String, Object?> metadata = <String, Object?>{
      'context': <String, Object?>{'tags': metadataTags},
    };
    final PixaRequest request = PixaRequest(
      source: PixaSource.network(Uri.parse('https://images.test/a.png')),
      headers: headers,
      headersPolicy: PixaHeadersPolicy(varyHeaders: varyHeaders),
      sources: sources,
      processors: processors,
      decoderOptions: decoderOptions,
      metadata: metadata,
    );
    final Object originalKey = request.cacheKey;
    final Uint8List originalPayload = PixaRuntimeLoader.encodeRequest(request);

    headers['X-Variant'] = 'two';
    sources.add(PixaSource.network(Uri.parse('https://images.test/other.png')));
    processors[0] = 'grayscale()';
    varyHeaders.add('X-Other');
    decoderOptions['mimeType'] = 'image/jpeg';
    decoderNested[0] = 2;
    (decoderNested[1]! as Map<String, Object?>)['mode'] = 'slow';
    metadataTags[0] = 'mutated';

    expect(request.headers, <String, String>{'X-Variant': 'one'});
    expect(request.sources, hasLength(1));
    expect(request.processors, <String>['resize(width=10)']);
    expect(request.headersPolicy.varyHeaders, <String>{'x-variant'});
    expect(request.decoderOptions['mimeType'], 'image/png');
    expect(
      ((request.decoderOptions['nested']! as List<Object?>)[1]!
          as Map<Object?, Object?>)['mode'],
      'fast',
    );
    expect(
      (((request.metadata['context']! as Map<Object?, Object?>)['tags']!
              as List<Object?>)
          .single),
      'original',
    );
    expect(request.cacheKey, originalKey);
    expect(
      PixaRuntimeLoader.encodeRequest(request),
      orderedEquals(originalPayload),
    );
    expect(() => request.headers['new'] = 'value', throwsUnsupportedError);
    expect(() => request.sources.add(request.source), throwsUnsupportedError);
    expect(() => request.processors.add('blur()'), throwsUnsupportedError);
    expect(
      () => request.headersPolicy.varyHeaders.add('other'),
      throwsUnsupportedError,
    );
  });

  test('bytes and memory sources own publicly immutable byte copies', () {
    final Uint8List callerBytes = Uint8List.fromList(<int>[1, 2, 3]);
    final PixaBytesSource bytesSource =
        PixaSource.bytes(callerBytes) as PixaBytesSource;
    final PixaMemorySource memorySource =
        PixaSource.memory('avatar', callerBytes) as PixaMemorySource;
    final Object bytesKey = PixaRequest(source: bytesSource).cacheKey;

    callerBytes[0] = 9;

    expect(bytesSource.bytes, <int>[1, 2, 3]);
    expect(memorySource.bytes, <int>[1, 2, 3]);
    expect(PixaRequest(source: bytesSource).cacheKey, bytesKey);
    expect(() => bytesSource.bytes[0] = 7, throwsUnsupportedError);
    expect(() => memorySource.bytes[0] = 7, throwsUnsupportedError);
  });

  test('request rejects values that cannot safely enter the runtime ABI', () {
    final PixaSource source = PixaSource.network(
      Uri.parse('https://images.test/a.png'),
    );

    expect(
      () => PixaRequest(source: source, scale: double.infinity),
      throwsArgumentError,
    );
    expect(
      () => PixaRequest(
        source: source,
        targetSize: const PixaTargetSize(width: 0x100000000),
      ),
      throwsArgumentError,
    );
    expect(
      () => PixaRequest(
        source: source,
        retryPolicy: const PixaRetryPolicy(maxAttempts: 0x100000000),
      ),
      throwsArgumentError,
    );
    expect(
      () => PixaRequest(
        source: source,
        limits: const PixaRequestLimits(maxEncodedBytes: 0),
      ),
      throwsArgumentError,
    );
  });
}
