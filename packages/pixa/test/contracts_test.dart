import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixa/pixa.dart';
import 'package:pixa/pixa_plugins.dart';

void main() {
  test('PixaManualCancellationSignal throws a typed cancel failure', () {
    final PixaManualCancellationSignal signal = PixaManualCancellationSignal();

    expect(signal.isCancellationRequested, isFalse);
    signal.cancel();

    expect(signal.isCancellationRequested, isTrue);
    expect(signal.whenCancelled, completes);
    expect(
      signal.throwIfCancellationRequested,
      throwsA(
        isA<PixaFailure>()
            .having(
              (PixaFailure failure) => failure.stage,
              'stage',
              PixaStage.cancel,
            )
            .having(
              (PixaFailure failure) => failure.retryability,
              'retryability',
              PixaRetryability.notRetryable,
            ),
      ),
    );
  });

  test(
    'PixaBytePayload preserves caller-owned bytes without implicit copy',
    () {
      final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3]);
      final PixaBytePayload payload = PixaBytePayload(
        bytes: bytes,
        mimeType: 'image/png',
        metadata: const <String, Object?>{'source': 'test'},
      );

      expect(identical(payload.bytes, bytes), isTrue);
      expect(payload.kind, PixaPayloadKind.encodedImage);
      expect(payload.mimeType, 'image/png');
      expect(payload.metadata, <String, Object?>{'source': 'test'});
    },
  );

  test(
    'fetcher, processor, cache store, and scheduler contracts compose',
    () async {
      final PixaRequest request = PixaRequest.network(
        'https://example.com/a.png',
      );
      final PixaManualCancellationSignal signal =
          PixaManualCancellationSignal();
      final List<PixaProgress> progress = <PixaProgress>[];
      final PixaExecutionContext context = PixaExecutionContext(
        requestId: 7,
        request: request,
        cancellationSignal: signal,
        onProgress: progress.add,
      );
      final PixaCacheStore cacheStore = _MemoryCacheStore();
      final PixaScheduler scheduler = _PassthroughScheduler();
      final PixaFetcher fetcher = _StaticFetcher();
      final PixaProcessor processor = _TagProcessor();

      final PixaBytePayload fetched = await scheduler.schedule<PixaBytePayload>(
        request,
        (PixaExecutionContext scheduledContext) {
          expect(identical(scheduledContext, context), isTrue);
          return Future<PixaBytePayload>.value(
            fetcher.fetch(request.source, scheduledContext),
          );
        },
        context,
      );
      final PixaBytePayload processed = await processor.process(
        fetched,
        PixaProcessorContext(
          execution: context,
          operation: 'tag',
          arguments: const <String, Object?>{'tag': 'thumb'},
        ),
      );
      await cacheStore.write(
        request.cacheNamespace,
        'abcdef0123456789',
        processed,
        PixaCacheWriteContext(
          execution: context,
          ttl: const Duration(minutes: 1),
        ),
      );
      final PixaCacheLookup lookup = await cacheStore.read(
        request.cacheNamespace,
        'abcdef0123456789',
        context,
      );

      expect(progress.single.stage, PixaStage.fetch);
      expect(lookup, isA<PixaCacheHit>());
      expect((lookup as PixaCacheHit).payload.metadata['tag'], 'thumb');
      expect(lookup.isStale, isFalse);
    },
  );

  test('controller hook provides no-op defaults with selective override', () {
    final PixaRequest request = PixaRequest.network(
      'https://example.com/a.png',
    );
    final _AttachCountingHook hook = _AttachCountingHook();

    hook
      ..onAttach(request)
      ..onDetach(request)
      ..onVisibilityChanged(request, visible: false)
      ..onDispose(request);

    expect(hook.attachCount, 1);
  });
}

final class _StaticFetcher implements PixaFetcher {
  @override
  PixaBytePayload fetch(PixaSource source, PixaExecutionContext context) {
    context.emit(
      PixaProgress(
        requestId: context.requestId,
        stage: PixaStage.fetch,
        receivedBytes: 3,
        expectedBytes: 3,
      ),
    );
    return PixaBytePayload(
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      mimeType: 'image/png',
    );
  }
}

final class _TagProcessor implements PixaProcessor {
  @override
  PixaBytePayload process(PixaBytePayload input, PixaProcessorContext context) {
    return PixaBytePayload(
      bytes: input.bytes,
      mimeType: input.mimeType,
      metadata: <String, Object?>{
        ...input.metadata,
        'tag': context.arguments['tag'],
      },
    );
  }
}

final class _MemoryCacheStore implements PixaCacheStore {
  final Map<String, PixaBytePayload> _entries = <String, PixaBytePayload>{};

  @override
  PixaCacheLookup read(
    String namespace,
    String key,
    PixaExecutionContext context,
  ) {
    final PixaBytePayload? payload = _entries['$namespace:$key'];
    return payload == null
        ? const PixaCacheMiss()
        : PixaCacheHit(payload: payload, isStale: false);
  }

  @override
  void write(
    String namespace,
    String key,
    PixaBytePayload payload,
    PixaCacheWriteContext context,
  ) {
    _entries['$namespace:$key'] = payload;
  }

  @override
  void remove(String namespace, String key) {
    _entries.remove('$namespace:$key');
  }

  @override
  void clearNamespace(String namespace) {
    _entries.removeWhere(
      (String key, PixaBytePayload _) => key.startsWith('$namespace:'),
    );
  }
}

final class _PassthroughScheduler implements PixaScheduler {
  @override
  Future<T> schedule<T>(
    PixaRequest request,
    Future<T> Function(PixaExecutionContext context) operation,
    PixaExecutionContext context,
  ) {
    return operation(context);
  }
}

final class _AttachCountingHook extends PixaControllerHook {
  int attachCount = 0;

  @override
  void onAttach(PixaRequest request) {
    attachCount++;
  }
}
