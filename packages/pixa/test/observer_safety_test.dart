import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';

void main() {
  test('observer attributes are deeply redacted and immutable', () {
    final List<Object?> mutableValues = <Object?>[
      Uri.parse(
        'https://alice:secret@example.test/image.jpg?access_token=alpha&ok=1#private',
      ),
    ];
    final Map<String, Object?> mutableNested = <String, Object?>{
      'Authorization': 'Bearer alpha',
      'values': mutableValues,
    };
    final Map<String, Object?> mutableAttributes = <String, Object?>{
      'token': 'alpha',
      'nested': mutableNested,
      'count': 3,
    };

    final PixaEvent event = PixaEvent(
      requestId: 1,
      stage: PixaStage.fetch,
      name: 'observer.safety',
      attributes: mutableAttributes,
    );
    mutableAttributes['token'] = 'changed';
    mutableNested['Authorization'] = 'changed';
    mutableValues.add('changed');

    expect(event.attributes['token'], '<redacted>');
    expect(event.attributes['count'], 3);
    final Map<Object?, Object?> nested =
        event.attributes['nested']! as Map<Object?, Object?>;
    expect(nested['Authorization'], '<redacted>');
    final List<Object?> values = nested['values']! as List<Object?>;
    expect(values, hasLength(1));
    final String uri = values.single! as String;
    expect(uri, isNot(contains('alice')));
    expect(uri, isNot(contains('secret')));
    expect(uri, isNot(contains('alpha')));
    expect(uri, isNot(contains('private')));
    expect(uri, contains('ok=1'));
    expect(() => event.attributes['new'] = true, throwsUnsupportedError);
    expect(() => nested['new'] = true, throwsUnsupportedError);
    expect(() => values.add('new'), throwsUnsupportedError);
  });

  test('observer failure removes raw diagnostics and redacts safe text', () {
    final StateError original = StateError(
      'https://alice:secret@example.test/a?x-amz-signature=alpha#private',
    );
    final PixaFailure failure = PixaFailure(
      requestId: 2,
      stage: PixaStage.fetch,
      safeMessage: 'access_token=alpha',
      retryability: PixaRetryability.notRetryable,
      originalError: original,
      stackTrace: StackTrace.current,
    );

    final PixaEvent event = PixaEvent(
      requestId: 2,
      stage: PixaStage.fetch,
      name: 'request.failure',
      failure: failure,
    );

    expect(failure.originalError, same(original));
    expect(event.failure, isNot(same(failure)));
    expect(event.failure!.originalError, isNull);
    expect(event.failure!.stackTrace, isNull);
    expect(event.failure!.safeMessage, isNot(contains('alpha')));
  });

  test('observer progress and public previews detach mutable byte aliases', () {
    final Uint8List sourceBytes = Uint8List.fromList(<int>[1, 2, 3]);
    final PixaProgressivePreview preview = PixaProgressivePreview(
      bytes: sourceBytes,
      mimeType: 'image/jpeg',
      sequence: 1,
    );
    sourceBytes[0] = 9;

    final PixaEvent event = PixaEvent(
      requestId: 3,
      stage: PixaStage.fetch,
      name: 'fetch.progress',
      progress: PixaProgress(
        requestId: 3,
        stage: PixaStage.fetch,
        message: 'token=alpha',
        progressivePreview: preview,
      ),
    );

    expect(preview.bytes, <int>[1, 2, 3]);
    expect(() => preview.bytes[0] = 7, throwsUnsupportedError);
    expect(event.progress!.message, isNot(contains('alpha')));
    expect(event.progress!.progressivePreview, isNot(same(preview)));
    expect(event.progress!.progressivePreview!.bytes, <int>[1, 2, 3]);
    expect(event.progress!.progressivePreview!.retainedOwner, isNull);
  });
}
